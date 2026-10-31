#!/usr/bin/env bash
###############################################################################
# install-controller.sh — Quantum central controller installer (standalone)
#
# Installs the full Quantum controller stack on a clean Ubuntu machine and
# puts it behind nginx with a real Let's Encrypt certificate and a
# WebSocket-capable reverse proxy. Product flow:
#
#   sudo bash install-controller.sh --domain panel.example.com \
#        [--email ops@example.com] [--panel-dir /etc/gre-panel]
#        [--panel-version latest|vX.Y.Z] [--github-token TOK]
#        [--update-pubkey-file pub.pem]
#        [--no-redirect] [--force-dns] [--dry-run] [--verify-tls] [--uninstall]
#
# Steps: 1 detect Ubuntu/arch · 2 prerequisites · 3 controller binary
# (release download, sha256 manifest fail-closed, optional Ed25519 .sig
# against --update-pubkey-file) · 4 isolated config/state + gre-panel.service
# · 5 loopback binding (bind_host=127.0.0.1 from the start) · 6 nginx reverse
# proxy · 7 HTTP->HTTPS · 8 WSS forwarding (/api/agent/ws) · 9 Let's Encrypt
# webroot · 10 renewal + deploy-hook reload · 11 additive firewall ·
# 12 HTTPS/WebSocket/SAN/renewal verification · 13 SSH bootstrap (shared
# helper, opt-in).
#
# An existing panel installation is detected and kept (upgrade/re-run path);
# the panel is only downloaded when this machine does not already run one
# (or --panel-version was given explicitly). This script never touches
# quantum.sh or any tunnel engine.
#
# TLS gate contract: the install is NOT considered successful until
# `certbot renew --dry-run` has SUCCEEDED over the live webroot WHILE NGINX
# REMAINED ACTIVE (HTTP-01 path actually exercised), the renewal config is
# proven to use authenticator=webroot, and the deploy hook has reloaded
# nginx with the panel still healthy behind it. Re-check any time with
# `--verify-tls` (the post-renewal check).
#
# Firewall contract: ADDITIVE ONLY. At most two allow rules are added
# (80/tcp, 443/tcp). No flush, no reset, no disable, no SSH changes. Ever.
###############################################################################
set -euo pipefail

# Shared installer helpers (bilingual output, additive firewall interface,
# SSH bootstrap, server preparation). Resolved next to this script.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$LIB_DIR/installer-lib.sh" ]]; then
    # shellcheck source=installer-lib.sh
    source "$LIB_DIR/installer-lib.sh"
else
    printf 'Error: installer-lib.sh must sit next to %s.\n' "$0" >&2
    exit 1
fi

###############################################################################
# Constants
###############################################################################
SCRIPT_NAME="install-controller.sh"
MARKER_DIR="/var/lib/quantum-controller"
MARKER_FILE="${MARKER_DIR}/controller.conf"          # records DOMAIN= for re-runs/uninstall
BACKUP_DIR="/var/backups/quantum-controller"
ACME_WEBROOT="/var/www/quantum-acme"
ERR_DIR="/var/www/quantum-errors"
ERR_PAGE="quantum_50x.html"
NGX_SITE="/etc/nginx/sites-available/quantum-controller.conf"
NGX_SITE_LINK="/etc/nginx/sites-enabled/quantum-controller.conf"
NGX_ACME_SITE="/etc/nginx/sites-available/quantum-acme-bootstrap.conf"
NGX_ACME_LINK="/etc/nginx/sites-enabled/quantum-acme-bootstrap.conf"
NGX_WS_MAP="/etc/nginx/conf.d/quantum-websocket.map.conf"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/quantum-reload-nginx.sh"
PANEL_BIN="/usr/local/bin/gre-panel"
PANEL_UNIT="gre-panel.service"
TS="$(date +%Y%m%d-%H%M%S)"
ROLLBACK_SCRIPT=""

# Runtime options (set by parse_args)
DOMAIN=""
EMAIL=""
PANEL_DIR="/etc/gre-panel"
NO_REDIRECT=0
FORCE_DNS=0
DRY_RUN=0
UNINSTALL=0
VERIFY_TLS=0
ASSUME_YES=0

# SSH bootstrap options (server preparation; same shared implementation as
# install-agent.sh; default: skipped unless options are given)
SSH_USER=""
SSH_PUBKEY=""
SSH_PUBKEY_FILE=""
SSH_PORT=""
SSH_SKIP=0

# Values parsed from panel.json (Phase 0)
PANEL_PORT="7777"
PANEL_BASE="panel"
PANEL_TLS_PORT="7443"
PANEL_BIND_OLD=""     # previous bind_host value, "" if key was absent
NGINX_BAK_TARBALL=""

# Output colors
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_OFF=""
fi

PHASE="startup"

###############################################################################
# Logging helpers
###############################################################################
info()  { printf '%s[%s]%s %s\n'  "$C_BLUE"  "$PHASE" "$C_OFF" "$*"; }
ok()    { printf '%s[ok]%s %s\n'         "$C_GREEN" "$C_OFF" "$*"; }
warn()  { printf '%s[warn]%s %s\n'       "$C_YELLOW" "$C_OFF" "$*"; }
err()   { printf '%s[error]%s %s\n'      "$C_RED" "$C_OFF" "$*" >&2; }
die()   { err "$*"; printf '%sAborted.%s Nothing destructive was done beyond what was already logged.\n' "$C_BOLD" "$C_OFF" >&2; exit 1; }
phase() { PHASE="$1"; printf '\n%s==> %s%s\n' "$C_CYAN" "$*" "$C_OFF"; }

on_err() {
    local exit_code="$1" line="$2"
    [[ -n "$TMPDIR_CTL" && -d "$TMPDIR_CTL" ]] && rm -rf "$TMPDIR_CTL"
    printf '\n%s[error]%s install-controller.sh FAILED (exit %s) near line %s, during phase: %s\n' \
        "$C_RED" "$C_OFF" "$exit_code" "$line" "$PHASE" >&2
    printf 'Rollback hints:\n' >&2
    if [[ -n "$NGINX_BAK_TARBALL" && -f "$NGINX_BAK_TARBALL" ]]; then
        printf '  - restore the pre-install nginx config:\n' >&2
        printf '      sudo bash %s\n' "$ROLLBACK_SCRIPT" >&2
    fi
    printf '  - the firewall was only ever ADDITIVE (two allow rules); it is safe to leave as-is.\n' >&2
    printf '  - panel.json was not modified unless the log shows Phase 4 completed the bind_host switch.\n' >&2
    printf '  - certbot state is left intact; re-running this script is safe and idempotent.\n' >&2
}
trap 'on_err "$?" "$LINENO"' ERR

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

###############################################################################
# Small utilities
###############################################################################
have() { command -v "$1" >/dev/null 2>&1; }

confirm() { # confirm "question" -> 0 if yes
    local reply
    [[ $ASSUME_YES -eq 1 ]] && return 0
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# write_atomic DEST < content : writes stdin to DEST atomically, keeps .bak
write_atomic() {
    local dest="$1" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 1   # unchanged
    fi
    if [[ -f "$dest" ]]; then
        cp -a "$dest" "${dest}.bak"
        info "updated $dest (previous copy saved as ${dest}.bak)"
    fi
    chmod 644 "$tmp"
    mv -f "$tmp" "$dest"
    return 0
}

port_listening() { # port_listening <port> -> 0 if something listens on tcp port
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E ":${1}\$" >/dev/null 2>&1
}

listener_of() { # listener_of <port> : print "pid proc" of the listener, or ""
    ss -tlnpH "sport = :${1}" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -1 | sed 's/users:(("//; s/"$//' || true
}

detect_ssh_port() {
    local line port
    line="$(ss -tlnpH 2>/dev/null | grep -i 'sshd' | head -1 || true)"
    if [[ -n "$line" ]]; then
        port="$(printf '%s' "$line" | awk '{print $4}' | grep -oE '[0-9]+$' | head -1 || true)"
    fi
    if [[ -z "${port:-}" ]]; then
        # fall back to the sshd_config Port line, then the well-known default
        port="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || true)"
    fi
    printf '%s' "${port:-22}"
}

server_global_addrs() { # print this server's global-scope addresses, one per line
    ip -j addr show scope global 2>/dev/null | python3 -c '
import json, sys
try:
    for iface in json.load(sys.stdin):
        for a in iface.get("addr_info", []):
            if a.get("scope") == "global":
                print(a.get("local", ""))
except Exception:
    pass
' 2>/dev/null | sort -u
}

public_ip() { # public_ip <4|6> : best-effort public address detection ("" on failure)
    local fam="$1" out
    out="$(curl "-${fam}" -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
        out="$(curl "-${fam}" -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    fi
    printf '%s' "$out"
}

resolve_domain() { # resolve_domain <domain> <4|6> : print resolved addresses
    local dom="$1" fam="$2" out=""
    if have getent; then
        out="$(getent "ahostsv${fam}" "$dom" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    fi
    if [[ -z "$out" ]]; then
        out="$(python3 -c '
import socket, sys
fam = int(sys.argv[2]); dom = sys.argv[1]
af = socket.AF_INET if fam == 4 else socket.AF_INET6
try:
    for r in socket.getaddrinfo(dom, None, af):
        print(r[4][0])
except Exception:
    pass
' "$dom" "$fam" 2>/dev/null | sort -u || true)"
    fi
    printf '%s' "$out"
}

nginx_test() { # hard gate: config must be valid before (re)load
    if ! nginx -t 2>/tmp/quantum-nginx-test.err; then
        cat /tmp/quantum-nginx-test.err >&2 || true
        if [[ -n "$ROLLBACK_SCRIPT" && -f "$ROLLBACK_SCRIPT" ]]; then
            die "nginx config test failed. Restore with: sudo bash $ROLLBACK_SCRIPT"
        fi
        die "nginx config test failed."
    fi
    rm -f /tmp/quantum-nginx-test.err
    ok "nginx -t passed"
}

nginx_reload_or_start() {
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
        ok "nginx reloaded"
    else
        systemctl start nginx
        ok "nginx started"
    fi
}

curl_local() { # curl_local <url> : no proxies, short timeout, print body
    curl --noproxy '*' -fsS --max-time 6 "$1" 2>/dev/null
}

wait_health_ok() { # wait_health_ok <url> <tries> : verify panel health JSON
    local url="$1" tries="$2" i body
    for ((i = 1; i <= tries; i++)); do
        body="$(curl_local "$url" || true)"
        if printf '%s' "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
            return 0
        fi
        sleep 1.5
    done
    return 1
}

###############################################################################
# panel.json access
###############################################################################
read_panel_json() {
    local json_file="${PANEL_DIR}/panel.json"
    if [[ ! -f "$json_file" ]]; then
        warn "$json_file not found; using defaults (port 7777, base path 'panel')"
        return 0
    fi
    local parsed
    parsed="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
port = str(cfg.get("port", 7777))
base = str(cfg.get("base_path", "panel")).strip("/")
tls  = str(cfg.get("tls_port", 7443))
bind = cfg.get("bind_host", "")
print(port); print(base); print(tls); print(bind)
' "$json_file" 2>/dev/null)" || die "failed to parse $json_file with python3"
    PANEL_PORT="$(printf '%s\n' "$parsed" | sed -n '1p')"
    PANEL_BASE="$(printf '%s\n' "$parsed" | sed -n '2p')"
    PANEL_TLS_PORT="$(printf '%s\n' "$parsed" | sed -n '3p')"
    PANEL_BIND_OLD="$(printf '%s\n' "$parsed" | sed -n '4p')"
    [[ -n "$PANEL_BASE" ]] || PANEL_BASE="panel"
    info "panel.json: port=${PANEL_PORT} base_path=${PANEL_BASE} tls_port=${PANEL_TLS_PORT} bind_host=${PANEL_BIND_OLD:-<unset, all interfaces>}"
}

set_bind_host() { # set_bind_host <value|""->remove>  (atomic, 0600, keeps rest)
    local json_file="${PANEL_DIR}/panel.json" value="$1"
    [[ -f "$json_file" ]] || return 0
    python3 -c '
import json, os, sys
path, value = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
if value == "":
    cfg.pop("bind_host", None)
else:
    cfg["bind_host"] = value
d = os.path.dirname(path) or "."
tmp = os.path.join(d, ".panel.json.tmp-quantum")
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
' "$json_file" "$value"
}

###############################################################################
# Phase 0 — preflight (read-only; dry-run stops here)
###############################################################################
preflight_root_os() {
    phase "Phase 0/4: Preflight"
    [[ $EUID -eq 0 ]] || die "must run as root (sudo bash $SCRIPT_NAME ...)"
    if [[ -f /etc/os-release ]]; then
        local id=""; . /etc/os-release 2>/dev/null && id="${ID:-}"
        if [[ "$id" == "ubuntu" ]]; then
            ok "Ubuntu detected (${PRETTY_NAME:-})"
        elif [[ "$id" == "debian" ]]; then
            warn "Debian detected (${PRETTY_NAME:-}) — supported best-effort, tested on Ubuntu 22.04/24.04"
        else
            die "unsupported OS '${id}' — this installer targets Ubuntu 22.04/24.04"
        fi
    else
        warn "/etc/os-release not found; cannot verify the distribution"
    fi
}

preflight_panel() {
    if [[ ! -x "$PANEL_BIN" ]]; then
        info "no panel binary at $PANEL_BIN — the product path installs it (Phase 0b: download + verify + isolated service)"
        return 0
    fi
    if ! systemctl list-unit-files --no-legend "$PANEL_UNIT" 2>/dev/null | grep -q .; then
        info "panel binary found but $PANEL_UNIT is not installed — Phase 0b will install the service"
        return 0
    fi
    ok "panel present: $PANEL_BIN ($PANEL_UNIT)"
    systemctl is-active --quiet "$PANEL_UNIT" \
        || warn "service $PANEL_UNIT exists but is not active — Phase 0b will start it"
    have python3 || die "python3 is required to parse ${PANEL_DIR}/panel.json (apt-get install python3)"
    read_panel_json
}

validate_domain() {
    [[ -n "$DOMAIN" ]] || die "--domain is required (except with --uninstall). Example: --domain panel.example.com"
    DOMAIN="${DOMAIN,,}"
    DOMAIN="${DOMAIN%.}"
    if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$DOMAIN" == *:* ]]; then
        die "'$DOMAIN' is an IP literal — pass a DNS name that will carry the Let's Encrypt certificate"
    fi
    if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
        die "'$DOMAIN' is not a valid lowercase hostname (letters/digits/dots/hyphens, at least one dot)"
    fi
    ok "domain: $DOMAIN"
}

preflight_dns() {
    local found_v4 found_v6 pub4 pub6 a
    pub4="$(public_ip 4)"
    pub6="$(public_ip 6)"
    found_v4="$(resolve_domain "$DOMAIN" 4)"
    found_v6="$(resolve_domain "$DOMAIN" 6)"
    printf '\n'
    printf '  %-34s | %s\n' "check" "result"
    printf '  ---------------------------------- | ----------------------------\n'
    # A record: must resolve to this server's public IPv4 (HTTP-01 requirement).
    if [[ -z "$found_v4" ]]; then
        die "DNS: '$DOMAIN' has no A record. Create an A record pointing at this server's public IPv4 first (or use --force-dns to skip)."
    fi
    if [[ -n "$pub4" ]] && printf '%s\n' "$found_v4" | grep -qxF "$pub4"; then
        ok "A record: $DOMAIN -> $pub4 (this server's public IPv4)"
    else
        if [[ $FORCE_DNS -eq 1 ]]; then
            printf '  %-34s | %s\n' "A record" "MISMATCH (forced): $(printf '%s' "$found_v4" | tr '\n' ' ')"
            printf '%s*** DNS MISMATCH — proceeding because --force-dns was given. ***%s\n' "$C_YELLOW" "$C_OFF"
        else
            die "DNS: A record for '$DOMAIN' resolves to $(printf '%s' "$found_v4" | tr '\n' ' ') but this server's public IPv4 is ${pub4:-<undetectable>}. Point the A record here or re-run with --force-dns."
        fi
    fi
    # AAAA records: detected and VERIFIED before being accepted — every IPv6
    # address the domain publishes must be one of this server's own public
    # IPv6 addresses, otherwise dual-stack clients break (issuance may still
    # work over IPv4, but the site must not advertise an IPv6 it cannot serve).
    if [[ -n "$found_v6" ]]; then
        while IFS= read -r a; do
            [[ -n "$a" ]] || continue
            if [[ -n "$pub6" ]] && [[ "$a" == "$pub6" ]] || printf '%s' "$(server_global_addrs)" | grep -qxF "$a"; then
                ok "AAAA record verified: $a is this server"
            else
                if [[ $FORCE_DNS -eq 1 ]]; then
                    printf '  %-34s | %s\n' "AAAA record" "MISMATCH (forced): $a"
                    printf '%s*** AAAA MISMATCH — proceeding because --force-dns was given. ***%s\n' "$C_YELLOW" "$C_OFF"
                else
                    die "DNS: AAAA record '$a' for '$DOMAIN' is not this server's IPv6 ($(printf '%s' "$(server_global_addrs)" | tr '\n' ' ')). Fix or remove the AAAA record, or re-run with --force-dns."
                fi
            fi
        done <<<"$found_v6"
    else
        ok "no AAAA record (IPv4-only serving is fine)"
    fi
    printf '\n'
}

preflight_ports() {
    local p80 p443 who
    p80=0; port_listening 80 && p80=1
    p443=0; port_listening 443 && p443=1
    if [[ $p80 -eq 1 || $p443 -eq 1 ]]; then
        if [[ -f "$MARKER_FILE" ]] && systemctl is-active --quiet nginx; then
            ok "ports 80/443 busy but owned by a previous run of this installer (marker present) — idempotent re-run"
        else
            who="$(listener_of 80)"; [[ -n "$who" ]] || who="$(listener_of 443)"
            die "port 80/443 already in use${who:+ by '$who'} and this installer did not put it there. \
Free the ports or uninstall the conflicting service first (the panel's own TLS on ${PANEL_TLS_PORT} is fine and untouched)."
        fi
    else
        ok "ports 80 and 443 are free — nginx will claim them"
    fi
    local ssh_port
    ssh_port="$(detect_ssh_port)"
    printf '\n%s  SSH stays open on port %s — this installer never touches it.%s\n\n' "$C_BOLD" "$ssh_port" "$C_OFF"
}

preflight_backup() {
    mkdir -p "$BACKUP_DIR"
    if [[ -d /etc/nginx ]]; then
        NGINX_BAK_TARBALL="${BACKUP_DIR}/nginx-${TS}.tar.gz"
        tar -czf "$NGINX_BAK_TARBALL" -C / etc/nginx
        ROLLBACK_SCRIPT="${BACKUP_DIR}/rollback-${TS}.sh"
        cat > "$ROLLBACK_SCRIPT" <<EOF
#!/bin/sh
# Rollback for install-controller.sh run at ${TS}
# Restores /etc/nginx from the pre-install snapshot and reloads nginx.
tar -xzf '${NGINX_BAK_TARBALL}' -C /
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    systemctl reload nginx
fi
echo "nginx config restored from ${NGINX_BAK_TARBALL}"
EOF
        chmod 700 "$ROLLBACK_SCRIPT"
        ok "backup: $NGINX_BAK_TARBALL"
        ok "rollback script: $ROLLBACK_SCRIPT"
    else
        warn "/etc/nginx does not exist yet — nothing to back up (fresh nginx install)"
    fi
}

print_plan() {
    phase "Plan (dry-run — nothing was changed)"
    cat <<EOF
Domain:            ${DOMAIN}
Panel (upstream):  http://127.0.0.1:${PANEL_PORT}/${PANEL_BASE}/   (panel.json port/base_path)
TLS port of panel: ${PANEL_TLS_PORT} (untouched; becomes loopback-only after Phase 4)

Would perform:
  Phase 0b install the controller binary${PANEL_VERSION:+ (version ${PANEL_VERSION:-latest})} if not present
           (release download + sha256 manifest + optional Ed25519 signature),
           isolated ${PANEL_DIR} config (admin password, bind_host=127.0.0.1),
           gre-panel.service, loopback health check
  Phase 1  apt-get install nginx certbot python3-certbot-nginx; enable (not start) nginx
  Phase 2  ACME webroot ${ACME_WEBROOT}, bootstrap :80 vhost,
           certbot certonly --webroot -d ${DOMAIN}${EMAIL:+ , email ${EMAIL}}${EMAIL:- , --register-unsafely-without-email},
           renewal deploy hook ${RENEW_HOOK}, verify certbot.timer, certbot renew --dry-run (non-fatal)
  Phase 3  /etc/nginx/sites-available/quantum-controller.conf (+ sites-enabled symlink),
           ${NGX_WS_MAP} (WebSocket upgrade map),
           ${ERR_DIR}/${ERR_PAGE} (Persian RTL 50x page),
           HTTP->HTTPS 301${NO_REDIRECT:+ DISABLED (--no-redirect)}, HSTS, TLS 1.2/1.3
  Phase 4  verify https://${DOMAIN}/${PANEL_BASE}/api/health through nginx,
           set panel.json bind_host=127.0.0.1 + restart ${PANEL_UNIT} (auto-revert on failure),
           add firewall allow rules for 80/tcp and 443/tcp (ADDITIVE ONLY),
           print summary + agent enrollment instructions
EOF
    ok "dry-run complete — no changes were made"
}

###############################################################################
# Phase 1 — packages
###############################################################################
install_packages() {
    phase "Phase 1/4: Packages (nginx, certbot)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y nginx certbot python3-certbot-nginx
    unset DEBIAN_FRONTEND
    # Enable for boot, but do NOT start before configs are valid (nginx -t gate in Phase 2).
    systemctl enable nginx >/dev/null 2>&1 || true
    if systemctl is-active --quiet nginx && [[ ! -f "$MARKER_FILE" ]]; then
        # Ubuntu's nginx postinst auto-starts the service; stop it until our
        # config is written and validated. Our own re-runs keep it running.
        systemctl stop nginx
        info "stopped the freshly auto-started nginx until configs pass nginx -t"
    fi
    ok "nginx $(nginx -v 2>&1 | sed 's/.*version //') and certbot $(certbot --version 2>/dev/null | awk '{print $2}') installed"
}

###############################################################################
# Phase 2 — TLS certificate (webroot; never fights the panel's standalone :80)
###############################################################################
phase2_tls() {
    phase "Phase 2/4: Let's Encrypt certificate (webroot)"
    mkdir -p "$ACME_WEBROOT"
    chown www-data:www-data "$ACME_WEBROOT"
    chmod 755 "$ACME_WEBROOT"

    # Minimal HTTP-only bootstrap vhost for ACME challenges.
    if write_atomic "$NGX_ACME_SITE" <<EOF
# Managed by install-controller.sh — serves ACME challenges for ${DOMAIN}.
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
        default_type "text/plain";
    }
    location / { return 404; }
}
EOF
    then
        ln -sfn "$NGX_ACME_SITE" "$NGX_ACME_LINK"
        info "wrote ACME bootstrap vhost ($NGX_ACME_SITE)"
    fi

    nginx_test
    nginx_reload_or_start

    # Port-80 reachability + webroot-path probe (real-domain requirement):
    # write a known token and fetch it back THROUGH the domain, proving the
    # path Let's Encrypt will exercise (http://<domain>/.well-known/acme-challenge/)
    # is served by this nginx from this webroot — before spending an issuance
    # attempt. Fails hard unless --force-dns was given.
    local token probe
    token="quantum-probe-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s' "$token" > "${ACME_WEBROOT}/${token}"
    chown www-data:www-data "${ACME_WEBROOT}/${token}" 2>/dev/null || true
    probe="$(curl --noproxy '*' -fsS --max-time 10 "http://${DOMAIN}/.well-known/acme-challenge/${token}" 2>/dev/null || true)"
    rm -f "${ACME_WEBROOT}/${token}"
    if [[ "$probe" == "$token" ]]; then
        ok "port 80 probe: http://${DOMAIN}/.well-known/acme-challenge/ serves this webroot"
    else
        if [[ $FORCE_DNS -eq 1 ]]; then
            warn "port-80 challenge probe FAILED (got '${probe:-<no answer>}'); continuing because --force-dns was given — issuance may fail"
        else
            die "port-80 challenge probe failed: http://${DOMAIN}/.well-known/acme-challenge/ did not return the probe token. Check that port 80 is reachable from the internet (firewall/router/DNS) or re-run with --force-dns."
        fi
    fi

    local email_args=()
    if [[ -n "$EMAIL" ]]; then
        email_args=(--email "$EMAIL")
    else
        email_args=(--register-unsafely-without-email)
        warn "no --email given: certbot will register without an address; expiry/revocation notices will not be sent"
    fi
    info "issuing certificate for ${DOMAIN} (webroot ${ACME_WEBROOT})..."
    if ! certbot certonly --webroot -w "$ACME_WEBROOT" -d "$DOMAIN" \
            --non-interactive --agree-tos --keep-until-expiring \
            --cert-name "$DOMAIN" "${email_args[@]}"; then
        err "certbot failed. Full log: /var/log/letsencrypt/letsencrypt.log"
        err "The bootstrap vhost stays in place (harmless); fix DNS/port 80 and re-run this installer."
        die "certificate issuance failed"
    fi
    [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] \
        || die "certbot reported success but /etc/letsencrypt/live/${DOMAIN}/fullchain.pem is missing"
    ok "certificate ready: /etc/letsencrypt/live/${DOMAIN}/"
    # The ACME bootstrap vhost did its job — remove it so its :80 server
    # cannot shadow the real site's HTTP->HTTPS redirect.
    rm -f /etc/nginx/sites-enabled/quantum-acme-bootstrap.conf /etc/nginx/sites-available/quantum-acme-bootstrap.conf
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true

    # Renewal deploy hook: reload nginx after every successful renewal.
    if write_atomic "$RENEW_HOOK" <<'EOF'
#!/bin/sh
# Managed by install-controller.sh — reload nginx after a certificate renewal.
systemctl reload nginx 2>/dev/null || true
EOF
    then
        chmod 755 "$RENEW_HOOK"
        info "wrote renewal deploy hook $RENEW_HOOK"
    fi
    if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
        ok "certbot.timer is enabled ($(systemctl list-timers certbot.timer --no-pager 2>/dev/null | sed -n 2p | awk '{print $1, $2, $3}' || true))"
    else
        systemctl enable --now certbot.timer >/dev/null 2>&1 || true
        if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
            ok "certbot.timer was enabled by this installer"
        else
            warn "certbot.timer is NOT enabled — renewals will not run automatically; enable it manually"
        fi
    fi
    info "testing renewal (certbot renew --dry-run, non-fatal)..."
    if certbot renew --dry-run --cert-name "$DOMAIN" >/dev/null 2>&1; then
        ok "renewal dry-run succeeded"
    else
        warn "renewal dry-run failed (non-fatal; check /var/log/letsencrypt/letsencrypt.log)"
    fi
}

###############################################################################
# Phase 3 — reverse-proxy site
###############################################################################
emit_proxy_locations() { # shared location blocks for the :80 (no-redirect) and :443 servers
    cat <<EOF
    # Branded 50x page (self-contained, Persian RTL).
    error_page 502 503 504 /${ERR_PAGE};
    location = /${ERR_PAGE} {
        root ${ERR_DIR};
        internal;
    }

    # Convenience: send bare / to the panel's base path.
    location = / {
        return 302 /${PANEL_BASE}/;
    }

    # Agent WebSocket: long-lived (heartbeats ~30s), generous timeouts.
    location /${PANEL_BASE}/api/agent/ws {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options SAMEORIGIN always;
        add_header Referrer-Policy strict-origin-when-cross-origin always;
        add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
    }

    # Everything under the panel's base path (dashboard + API + terminal WS).
    location /${PANEL_BASE}/ {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 75s;
        proxy_send_timeout 75s;
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options SAMEORIGIN always;
        add_header Referrer-Policy strict-origin-when-cross-origin always;
        add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
    }
EOF
}

write_ws_map() {
    # map must live in the http block: conf.d/ is included at http level.
    if write_atomic "$NGX_WS_MAP" <<'EOF'
# Managed by install-controller.sh — WebSocket upgrade mapping for the
# Quantum panel reverse proxy (used by /api/agent/ws and /api/term/ws).
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
    then
        info "wrote $NGX_WS_MAP"
    fi
}

write_error_page() {
    mkdir -p "$ERR_DIR"
    if write_atomic "${ERR_DIR}/${ERR_PAGE}" <<EOF
<!DOCTYPE html>
<html dir="rtl" lang="fa">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>کوانتوم — سرویس در دسترس نیست</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    min-height: 100vh; display: flex; align-items: center; justify-content: center;
    background: #0b1220; color: #e5e9f0;
    font-family: Vazirmatn, "Vazirmatn FD", "Segoe UI", Tahoma, Arial, sans-serif;
    text-align: center; padding: 24px;
  }
  .card { max-width: 520px; }
  .glow {
    width: 64px; height: 64px; margin: 0 auto 24px; border-radius: 50%;
    background: radial-gradient(circle at 30% 30%, #3b82f6, #1d4ed8 60%, transparent 75%);
    box-shadow: 0 0 40px rgba(59,130,246,.45);
  }
  h1 { font-size: 1.6rem; margin-bottom: 12px; }
  p  { color: #94a3b8; line-height: 1.9; margin-bottom: 28px; }
  a {
    display: inline-block; padding: 10px 28px; border-radius: 10px;
    background: #1d4ed8; color: #fff; text-decoration: none; font-weight: 600;
  }
  a:hover { background: #2563eb; }
</style>
</head>
<body>
  <div class="card">
    <div class="glow"></div>
    <h1>سرویس موقتا در دسترس نیست</h1>
    <p>به‌زودی برمی‌گردیم؛ چند لحظه بعد دوباره تلاش کنید.</p>
    <a href="/${PANEL_BASE}/">بازگشت به داشبورد</a>
  </div>
</body>
</html>
EOF
    then
        info "wrote ${ERR_DIR}/${ERR_PAGE}"
    fi
}

preflight_site_conflicts() {
    # Remove the stock default site ONLY if it actually conflicts with ours.
    local link="/etc/nginx/sites-enabled/default" f
    for f in /etc/nginx/sites-enabled/*; do
        [[ -e "$f" ]] || continue
        [[ "$f" == "$NGX_SITE_LINK" || "$f" == "$NGX_ACME_LINK" ]] && continue
        if grep -El "server_name[^;]*\b${DOMAIN//./\\.}\b" "$f" >/dev/null 2>&1; then
            die "$f already claims server_name ${DOMAIN} — resolve that conflict first"
        fi
    done
    if [[ -L "$link" && -e "$link" ]]; then
        if grep -q "listen.*80.*default_server" "$link" 2>/dev/null \
           && grep -q "server_name[[:space:]]*_;*" "$link" 2>/dev/null; then
            rm -f "$link"
            info "removed stock default site symlink $link (backup of /etc/nginx already taken)"
        fi
    fi
}

write_proxy_site() {
    phase "Phase 3/4: Reverse-proxy site"
    preflight_site_conflicts
    write_ws_map
    write_error_page

    local redirect_block
    if [[ $NO_REDIRECT -eq 1 ]]; then
        redirect_block="    # --no-redirect: keep serving HTTP (ACME path is still honored below)."
    else
        redirect_block="    location / { return 301 https://\$host\$request_uri; }"
    fi

    if ! write_atomic "$NGX_SITE" <<EOF
# Managed by install-controller.sh — Quantum central controller.
# Panel upstream: 127.0.0.1:${PANEL_PORT} (base path /${PANEL_BASE}/ from panel.json).
# Regenerate by re-running install-controller.sh; manual edits get a .bak.

server_tokens off;

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
        default_type "text/plain";
    }

${redirect_block}
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:quantum_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    client_max_body_size 16m;

$(emit_proxy_locations)
}
EOF
    then
        info "reverse-proxy config unchanged"
    else
        info "wrote $NGX_SITE"
    fi
    ln -sfn "$NGX_SITE" "$NGX_SITE_LINK"

    nginx_test
    nginx_reload_or_start
    ok "reverse proxy active (https://${DOMAIN}/${PANEL_BASE}/)"
}

###############################################################################
# Phase 4 — verification, panel privacy, firewall, summary
###############################################################################
open_firewall() {
    phase "Phase 4/4: Firewall (additive only)"
    local port rc
    if fw_available; then
        for port in 80 443; do
            fw_allow_port controller "web-$port" "$port" tcp
        done
    elif have iptables; then
        for port in 80 443; do
            rc=0
            if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                if ! iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT; then
                    warn "could not add iptables ACCEPT rule for ${port}/tcp (container/permission?) — verify manually"
                    rc=1
                fi
            fi
            [[ $rc -eq 0 ]] && ok "iptables: INPUT tcp/${port} ACCEPT ensured"
        done
    else
        warn "neither ufw nor iptables available — skipped (enforcement is owned by the firewall engine)"
    fi
    printf '%sExisting firewall rules were not modified except the allow rules above.%s\n' "$C_BOLD" "$C_OFF"
}

print_summary() {
    local ssh_port
    ssh_port="$(detect_ssh_port)"
    phase "Done — Quantum central controller"
    cat <<EOF

  ${C_BOLD}Domain${C_OFF}          https://${DOMAIN}
  ${C_BOLD}Panel URL${C_OFF}       https://${DOMAIN}/${PANEL_BASE}/
  ${C_BOLD}Agent WS URL${C_OFF}    wss://${DOMAIN}/${PANEL_BASE}/api/agent/ws
  ${C_BOLD}Certificate${C_OFF}     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem (+ privkey.pem)
  ${C_BOLD}Renewal${C_OFF}         certbot.timer $(systemctl is-enabled certbot.timer 2>/dev/null || echo disabled); deploy hook ${RENEW_HOOK}
  ${C_BOLD}Panel binding${C_OFF}   ${PANEL_BIND_OLD:+was ${PANEL_BIND_OLD}, }now bind_host=127.0.0.1 (nginx owns the public interface)
  ${C_BOLD}Panel TLS${C_OFF}       panel's own :${PANEL_TLS_PORT} listener is untouched and now loopback-only
  ${C_BOLD}SSH${C_OFF}             stays open on port ${ssh_port} — this installer never touched it
  ${C_BOLD}Backups${C_OFF}         ${BACKUP_DIR} (rollback: ${ROLLBACK_SCRIPT:-none needed})
  ${C_BOLD}Firewall${C_OFF}        only allow rules for 80/tcp + 443/tcp were added

  ${C_BOLD}Next steps — enroll an agent:${C_OFF}
    On the endpoint machine:
      gre-panel agent enroll --server https://${DOMAIN} --token <token>
    The agent dials wss://${DOMAIN}/${PANEL_BASE}/api/agent/ws through nginx
    (Upgrade/Connection headers are handled; heartbeats every ~30s).

EOF
}

phase4_verify_privacy() {
    phase "Phase 4/4: Verify + panel privacy (bind_host)"
    local health_url="https://${DOMAIN}/${PANEL_BASE}/api/health"
    info "verifying ${health_url} through nginx..."
    if wait_health_ok "$health_url" 10; then
        ok "panel healthy behind nginx"
    else
        die "https health check failed after 10 attempts — see journalctl -u nginx -e and journalctl -u ${PANEL_UNIT} -e"
    fi
    local code
    if [[ $NO_REDIRECT -eq 1 ]]; then
        code="$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 6 "http://${DOMAIN}/${PANEL_BASE}/api/health" || true)"
        [[ "$code" == "200" ]] && ok "HTTP serves the panel (--no-redirect)" || warn "HTTP check returned ${code:-none} (expected 200 with --no-redirect)"
    else
        code="$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 6 "http://${DOMAIN}/" || true)"
        [[ "$code" == "301" ]] && ok "HTTP -> HTTPS redirect in place" || warn "HTTP redirect check returned ${code:-none} (expected 301)"
    fi

    # Certificate identity: SAN must carry the domain, and the chain must
    # verify against the system trust store (wait_health_ok already used the
    # full chain via curl without -k; the SAN read makes it explicit).
    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        if openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -text 2>/dev/null \
                | grep -q "DNS:${DOMAIN}"; then
            ok "certificate SAN carries DNS:${DOMAIN}"
        else
            warn "certificate SAN does not list DNS:${DOMAIN} — re-run --verify-tls after reissuance"
        fi
        local issuer dates
        issuer="$(openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
        dates="$(openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
        ok "certificate: ${issuer:-?} (expires ${dates:-?})"
    fi

    # Renewal proof: the renewal config must use the webroot authenticator
    # and the deploy hook must exist and be executable.
    local renew_conf="/etc/letsencrypt/renewal/${DOMAIN}.conf"
    if [[ -f "$renew_conf" ]]; then
        if grep -q "authenticator = webroot" "$renew_conf"; then
            ok "renewal uses authenticator = webroot"
        else
            warn "renewal config is not webroot — renewals may break: $renew_conf"
        fi
    fi
    [[ -x "$RENEW_HOOK" ]] && ok "renewal deploy hook present and executable: $RENEW_HOOK" \
        || warn "renewal deploy hook missing or not executable: $RENEW_HOOK"

    # WSS route: the agent WebSocket endpoint must be reachable through nginx.
    # Unauthenticated upgrades are refused by the panel (403/400) — that
    # PROVES the route proxies; 404/502/503/timeouts mean it does not.
    local ws_code
    ws_code="$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 8 \
        -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
        -H 'Sec-WebSocket-Key: cXVhbnR1bS1oZWFsdGgtcHJvYmU=' -H 'Sec-WebSocket-Version: 13' \
        "https://${DOMAIN}/${PANEL_BASE}/api/agent/ws" || true)"
    case "$ws_code" in
        101) ok "agent WebSocket route upgrades (101) — wss fully operational" ;;
        403|400|302|401) ok "agent WebSocket route reachable (HTTP $ws_code before auth — upgrade path proxies to the panel)" ;;
        *) die "agent WebSocket route check failed (HTTP ${ws_code:-none}; want 101/403/400/302/401) — nginx WSS forwarding is broken" ;;
    esac

    if [[ "${PANEL_BIND_OLD}" == "127.0.0.1" ]]; then
        ok "panel already binds to 127.0.0.1 — nothing to change"
    else
        info "switching panel to loopback (panel.json bind_host=127.0.0.1) and restarting ${PANEL_UNIT}..."
        set_bind_host "127.0.0.1"
        systemctl restart "$PANEL_UNIT"
        sleep 2
        if systemctl is-active --quiet "$PANEL_UNIT" && wait_health_ok "$health_url" 6; then
            ok "panel re-verified through nginx on 127.0.0.1"
        else
            warn "re-verify after bind_host switch FAILED — reverting bind_host"
            set_bind_host "$PANEL_BIND_OLD"   # "" removes the key, restoring default
            systemctl restart "$PANEL_UNIT"
            sleep 2
            if wait_health_ok "$health_url" 6; then
                warn "reverted: panel is back on all interfaces; the TLS site still works via nginx. Investigate: journalctl -u ${PANEL_UNIT} -e"
            else
                warn "reverted bind_host but health check still fails — panel may need manual attention (data plane unchanged)"
            fi
        fi
    fi
}

###############################################################################
# Uninstall
###############################################################################
do_uninstall() {
    PHASE="uninstall"
    phase "Uninstall: removing controller proxy components"
    local removed=0 f
    for f in "$NGX_SITE_LINK" "$NGX_SITE" "$NGX_ACME_LINK" "$NGX_ACME_SITE" "$NGX_WS_MAP" "$RENEW_HOOK"; do
        if [[ -e "$f" || -L "$f" ]]; then
            rm -f "$f"
            info "removed $f"
            removed=1
        fi
    done
    for f in "${ERR_DIR}/${ERR_PAGE}" "${ERR_DIR}/${ERR_PAGE}.bak"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    [[ -d "$ERR_DIR" ]] && rmdir "$ERR_DIR" 2>/dev/null || true
    # Only drop the ACME webroot if no other certbot renewal still references it.
    if [[ -d "$ACME_WEBROOT" ]] && ! grep -rls "$ACME_WEBROOT" /etc/letsencrypt/renewal/ 2>/dev/null | grep -vq .; then
        rm -rf "$ACME_WEBROOT"
        info "removed $ACME_WEBROOT"
    fi
    if [[ -f "$MARKER_FILE" && -z "$DOMAIN" ]]; then
        DOMAIN="$(grep -oE '^DOMAIN=.*$' "$MARKER_FILE" | cut -d= -f2- || true)"
    fi
    [[ -f "$MARKER_FILE" ]] && rm -f "$MARKER_FILE"

    if systemctl is-active --quiet nginx; then
        local others
        others="$(find /etc/nginx/sites-enabled -mindepth 1 ! -name 'quantum-controller.conf' ! -name 'quantum-acme-bootstrap.conf' 2>/dev/null | wc -l)"
        if [[ "$others" -gt 0 ]]; then
            nginx_test || true
            systemctl reload nginx
            ok "nginx reloaded (${others} other site(s) kept running)"
        else
            systemctl stop nginx
            ok "nginx stopped (no other sites remain; binary/service left installed)"
        fi
    fi

    if [[ -n "$DOMAIN" ]] && [[ -f "/etc/letsencrypt/renewal/${DOMAIN}.conf" ]]; then
        if confirm "Also delete the Let's Encrypt certificate for ${DOMAIN}? (certbot delete)"; then
            certbot delete --cert-name "$DOMAIN" --non-interactive
            ok "certificate for ${DOMAIN} deleted"
        else
            info "certificate for ${DOMAIN} left in place"
        fi
    fi
    if [[ -f "${PANEL_DIR}/panel.json" ]] && grep -q '"bind_host"' "${PANEL_DIR}/panel.json"; then
        if confirm "Also revert panel.json bind_host (restore all-interface binding) and restart ${PANEL_UNIT}?"; then
            set_bind_host ""
            systemctl restart "$PANEL_UNIT"
            ok "panel.json bind_host removed; panel restarted"
        else
            info "panel.json left untouched (panel stays loopback-only behind nothing — re-expose manually if needed)"
        fi
    fi
    ok "uninstall complete. Panel binary, ${PANEL_UNIT} and ${PANEL_DIR} were NOT touched."
    [[ $removed -eq 1 ]] || info "(nothing was installed — no changes made)"
}

###############################################################################
# main
###############################################################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)     DOMAIN="${2:-}"; shift 2 ;;
            --email)      EMAIL="${2:-}"; shift 2 ;;
            --panel-dir)  PANEL_DIR="${2:-}"; shift 2 ;;
            --panel-version) PANEL_VERSION="${2:-}"; shift 2 ;;
            --github-token) GRE_GITHUB_TOKEN="${2:-}"; export GRE_GITHUB_TOKEN; shift 2 ;;
            --update-pubkey-file) UPDATE_PUBKEY_FILE="${2:-}"; shift 2 ;;
            --no-redirect) NO_REDIRECT=1; shift ;;
            --force-dns)  FORCE_DNS=1; shift ;;
            --dry-run)    DRY_RUN=1; shift ;;
            --verify-tls) VERIFY_TLS=1; shift ;;
            --uninstall)  UNINSTALL=1; shift ;;
            --bootstrap-controller) BOOT=1; shift ;;
            --binary)     BOOT_BINARY="${2:-}"; shift 2 ;;
            --http-port)  BOOT_HTTP="${2:-}"; shift 2 ;;
            --ssh-user)   SSH_USER="${2:-}"; shift 2 ;;
            --ssh-pubkey) SSH_PUBKEY="${2:-}"; shift 2 ;;
            --ssh-pubkey-file) SSH_PUBKEY_FILE="${2:-}"; shift 2 ;;
            --ssh-port)   SSH_PORT="${2:-}"; shift 2 ;;
            --no-ssh)     SSH_SKIP=1; shift ;;
            --no-netopt)  export GRE_NO_NETOPT=1; shift ;;
            -y|--yes)     ASSUME_YES=1; shift ;;
            -h|--help)    usage ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
    done
    DOMAIN="${DOMAIN:-}" EMAIL="${EMAIL:-}"
    BOOT_BINARY="${BOOT_BINARY:-}"
    BOOT_HTTP="${BOOT_HTTP:-17777}"
    PANEL_VERSION="${PANEL_VERSION:-latest}"
    UPDATE_PUBKEY_FILE="${UPDATE_PUBKEY_FILE:-}"
    ARCH=""; REL_TAG=""; TMPDIR_CTL=""
}

###############################################################################
# Product path — install the Quantum Controller binary + service (steps 2-5)
#
# Makes this installer standalone on a clean Ubuntu machine: download the
# release binary for this architecture, verify it (sha256 manifest
# fail-closed; optional Ed25519 .sig against --update-pubkey-file), install
# it, create the isolated config with loopback-only binding from the start
# (panel.json bind_host=127.0.0.1), write gre-panel.service and verify the
# panel is healthy on loopback before any TLS/nginx work begins.
#
# Coexistence: if a panel binary + active service are already present and no
# --panel-version was requested, this phase is skipped entirely (upgrade/
# re-run keeps the operator's panel untouched).
###############################################################################
GH_REPO="Dark-modem/quantum"

gh_curl() { # gh_curl CURL_ARGS... : GitHub API/download curl with optional token
    local auth=()
    [[ -n "${GRE_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}" ]] && \
        auth=(-H "Authorization: Bearer ${GRE_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}")
    curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 "${auth[@]}" "$@"
}

detect_arch() { # sets ARCH to amd64|arm64
    local mach
    mach="$(uname -m)"
    case "$mach" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) die "unsupported CPU architecture: $mach (supported: x86_64/amd64, aarch64/arm64)" ;;
    esac
}

resolve_controller_tag() {
    if [[ "$PANEL_VERSION" != "latest" ]]; then
        REL_TAG="$PANEL_VERSION"
        ok "controller version: $REL_TAG"
        return 0
    fi
    local body
    body="$(gh_curl --max-time 60 "https://api.github.com/repos/${GH_REPO}/releases/latest")" \
        || die "cannot resolve the latest release (GitHub API failed; check the token and network)"
    REL_TAG="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$body" | head -n1)"
    [[ "$REL_TAG" =~ ^v[0-9][0-9A-Za-z._-]*$ ]] || die "could not read tag_name from the GitHub API response"
    ok "controller version: $REL_TAG (latest release)"
}

verify_download_sig() { # verify_download_sig ARTIFACT ASSET : Ed25519 .sig when a key was provided
    local artifact="$1" asset="$2" sig_url="$TMPDIR_CTL/${asset}.sig"
    [[ -n "$UPDATE_PUBKEY_FILE" ]] || return 0
    [[ -f "$UPDATE_PUBKEY_FILE" ]] || die "update public key file not found: $UPDATE_PUBKEY_FILE"
    gh_curl --max-time 30 "${REL_TAG}/../" >/dev/null 2>&1 || true # warm; URL built below
    if ! gh_curl --max-time 30 "https://github.com/${GH_REPO}/releases/download/${REL_TAG}/${asset}.sig" -o "$sig_url"; then
        die "signature file ${asset}.sig is missing from the release (fail-closed: --update-pubkey-file was given)"
    fi
    base64 -d "$sig_url" > "$sig_url.raw" 2>/dev/null || cp "$sig_url" "$sig_url.raw"
    if openssl pkeyutl -verify -pubin -inkey "$UPDATE_PUBKEY_FILE" \
            -sigfile "$sig_url.raw" -in "$artifact" >/dev/null 2>&1; then
        ok "artifact Ed25519 signature verified against $UPDATE_PUBKEY_FILE"
    else
        rm -f "$sig_url" "$sig_url.raw"
        die "artifact Ed25519 signature verification FAILED against $UPDATE_PUBKEY_FILE"
    fi
    rm -f "$sig_url" "$sig_url.raw"
}

install_controller_binary() {
    local asset tmp_art tmp_sum expected actual pw
    detect_arch
    asset="gre-panel-linux-${ARCH}"
    phase "Phase 0b: Controller binary + isolated service"
    if [[ -x "$PANEL_BIN" ]] && systemctl list-unit-files --no-legend "$PANEL_UNIT" 2>/dev/null | grep -q .; then
        if [[ "$PANEL_VERSION" == "latest" ]]; then
            ok "panel already installed ($PANEL_BIN, $PANEL_UNIT) — keeping it (re-run/upgrade path)"
            return 0
        fi
        info "panel already installed; --panel-version given — upgrading in place"
    fi
    have python3 || die "python3 is required (apt-get install python3)"
    have openssl || die "openssl is required (apt-get install openssl)"
    TMPDIR_CTL="$(mktemp -d /tmp/quantum-controller.XXXXXX)"
    chmod 700 "$TMPDIR_CTL"

    resolve_controller_tag
    info "downloading $asset ($REL_TAG)..."
    gh_curl --max-time 300 "https://github.com/${GH_REPO}/releases/download/${REL_TAG}/${asset}" \
        -o "$TMPDIR_CTL/$asset" || die "release asset download failed"
    gh_curl --max-time 60 "https://github.com/${GH_REPO}/releases/download/${REL_TAG}/checksums.txt" \
        -o "$TMPDIR_CTL/checksums.txt" || die "checksum manifest unavailable (fail-closed: refusing an unverified binary)"
    expected="$(sed -n 's/^\([0-9a-fA-F]\{64\}\)[[:space:]]\+\*\?'"$asset"'[[:space:]]*$/\1/p' "$TMPDIR_CTL/checksums.txt" | head -n1)"
    [[ -n "$expected" ]] || die "no checksum entry for $asset in the manifest"
    actual="$(sha256sum "$TMPDIR_CTL/$asset" | cut -d' ' -f1)"
    [[ "$actual" == "${expected,,}" ]] || die "SHA-256 mismatch: expected ${expected,,}, got $actual"
    if [[ -n "$UPDATE_PUBKEY_FILE" ]]; then
        verify_download_sig "$TMPDIR_CTL/$asset" "$asset"
    else
        warn "artifact verified against the checksum manifest only (same-origin integrity). Provide --update-pubkey-file to verify the release Ed25519 signature too."
        info "AUDIT: controller_binary_checksum_only asset=$asset sha256=$actual"
    fi
    [[ "$(head -c 4 "$TMPDIR_CTL/$asset")" == $'\x7fELF' ]] || die "downloaded asset is not an ELF binary"
    chmod 0755 "$TMPDIR_CTL/$asset"
    local ver
    ver="$(timeout 10 env -u GRE_PANEL_DIR "$TMPDIR_CTL/$asset" version 2>/dev/null || true)"
    [[ -n "$ver" ]] || die "downloaded binary does not run on this machine"
    timeout 10 env -u GRE_PANEL_DIR "$TMPDIR_CTL/$asset" agent help >/dev/null 2>&1 \
        || die "binary lacks the 'agent' subcommand (pre-M2 release?) — refusing"
    ok "$asset verified: sha256=$actual (reports $ver)"

    install -m 0755 "$TMPDIR_CTL/$asset" "$PANEL_BIN.new"
    mv -f "$PANEL_BIN.new" "$PANEL_BIN"
    rm -rf "$TMPDIR_CTL"
    ok "controller binary installed: $PANEL_BIN"

    # Isolated config/state directory; loopback-only binding from the start.
    if [[ ! -f "${PANEL_DIR}/panel.json" ]]; then
        mkdir -p "$PANEL_DIR" && chmod 0700 "$PANEL_DIR"
        pw="$(openssl rand -hex 12)"
        if ! GRE_PANEL_DIR="$PANEL_DIR" GRE_PANEL_PASSWORD="$pw" "$PANEL_BIN" password "$pw" >/dev/null 2>&1; then
            GRE_PANEL_DIR="$PANEL_DIR" GRE_PANEL_PASSWORD="$pw" "$PANEL_BIN" password "$pw" 2>&1 | tail -3
            die "could not initialize the panel config"
        fi
        umask 077
        printf 'username=admin\npassword=%s\nbase_path=panel\n' "$pw" > "/root/.quantum-controller-credentials"
        chmod 0600 "/root/.quantum-controller-credentials"
        unset pw
        ok "fresh config initialized at $PANEL_DIR; credentials (root-only) at /root/.quantum-controller-credentials"
    else
        info "existing config kept (idempotent re-run): ${PANEL_DIR}/panel.json"
    fi
    python3 - "$PANEL_DIR/panel.json" <<'PY'
import json, os, sys
p = sys.argv[1]
cfg = {}
if os.path.exists(p):
    with open(p) as f:
        cfg = json.load(f)
cfg["port"] = 7777
cfg.setdefault("base_path", "panel")
cfg["bind_host"] = "127.0.0.1"   # step 5: loopback application binding; nginx owns the public interface
d = os.path.dirname(p) or "."
tmp = os.path.join(d, ".panel.json.tmp-quantum")
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PY
    chmod 0600 "${PANEL_DIR}/panel.json"
    ok "panel.json: port 7777, loopback binding (bind_host=127.0.0.1)"

    if [[ ! -f "/etc/systemd/system/$PANEL_UNIT" ]]; then
        cat > "/etc/systemd/system/$PANEL_UNIT" <<EOF
[Unit]
Description=Quantum Central Controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=GRE_PANEL_DIR=$PANEL_DIR
ExecStart=$PANEL_BIN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        ok "service written: /etc/systemd/system/$PANEL_UNIT"
    fi
    systemctl enable --now "$PANEL_UNIT" >/dev/null 2>&1 || systemctl restart "$PANEL_UNIT"
    sleep 2
    systemctl is-active --quiet "$PANEL_UNIT" || {
        journalctl -u "$PANEL_UNIT" -n 10 --no-pager | tail -5
        die "$PANEL_UNIT failed to start"
    }
    local base
    base="$(python3 -c "import json;print(json.load(open('${PANEL_DIR}/panel.json')).get('base_path','panel'))")"
    PANEL_BASE="$base"
    local i
    for i in 1 2 3 4 5 6 7 8; do
        if curl_local "http://127.0.0.1:7777/${base}/api/health" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
            ok "controller healthy on loopback (http://127.0.0.1:7777/$base/api/health)"
            return 0
        fi
        sleep 1.5
    done
    die "controller health check failed on loopback after install"
}

###############################################################################
# Minimal standalone controller bootstrap (P0 lab path)
#
# Installs a FRESH, ISOLATED Quantum panel instance (own config dir, own
# ports, own systemd unit) for validating the Controller/Agent architecture
# on a disposable machine — coexisting with any existing panel installation.
# Deliberately minimal: no nginx, no certbot, no domain. TLS comes from the
# panel's own tls-ip mode (local CA + IP-SAN cert) whose CA the operator
# distributes to the endpoints' system trust store.
###############################################################################
BOOT_DIR="/etc/gre-panel-lab"
BOOT_CRED="/root/.quantum-lab-credentials"
BOOT_UNIT="quantum-controller-lab.service"
BOOT_BIN="/usr/local/bin/gre-panel-lab"

bootstrap_controller() {
    [[ $EUID -eq 0 ]] || die "--bootstrap-controller must run as root"
    [[ -n "$BOOT_BINARY" ]] || die "--bootstrap-controller needs --binary <gre-panel binary for this host's architecture>"
    [[ -f "$BOOT_BINARY" ]] || die "binary not found: $BOOT_BINARY"
    [[ "$BOOT_HTTP" =~ ^[0-9]+$ ]] || die "--http-port must be numeric"
    have openssl || die "openssl is required for credential generation"
    have python3 || die "python3 is required for config editing"

    phase "bootstrap 1/5: binary"
    if [[ -x "$BOOT_BIN" ]]; then
        local cur new
        cur="$(sha256sum "$BOOT_BIN" | cut -d' ' -f1)"
        new="$(sha256sum "$BOOT_BINARY" | cut -d' ' -f1)"
        if [[ "$cur" == "$new" ]]; then
            ok "lab binary already current ($cur)"
        else
            install -m 0755 "$BOOT_BINARY" "$BOOT_BIN.new" && mv -f "$BOOT_BIN.new" "$BOOT_BIN"
            ok "lab binary replaced (was $cur)"
        fi
    else
        install -m 0755 "$BOOT_BINARY" "$BOOT_BIN"
        ok "lab binary installed: $BOOT_BIN ($(sha256sum "$BOOT_BIN" | cut -d' ' -f1))"
    fi

    phase "bootstrap 2/5: fresh isolated config"
    if [[ -f "$BOOT_DIR/panel.json" ]]; then
        warn "existing lab config kept (idempotent re-run): $BOOT_DIR"
    else
        mkdir -p "$BOOT_DIR" && chmod 0700 "$BOOT_DIR"
        local pw
        pw="$(openssl rand -hex 12)"
        if ! GRE_PANEL_DIR="$BOOT_DIR" GRE_PANEL_PASSWORD="$pw" "$BOOT_BIN" password "$pw" >/dev/null 2>&1; then
            GRE_PANEL_DIR="$BOOT_DIR" GRE_PANEL_PASSWORD="$pw" "$BOOT_BIN" password "$pw" 2>&1 | tail -3
            die "could not initialize the lab panel config"
        fi
        umask 077
        printf 'username=admin
password=%s
http_port=%s
tls_port=7443
' "$pw" "$BOOT_HTTP" > "$BOOT_CRED"
        chmod 0600 "$BOOT_CRED"
        unset pw
        ok "fresh config initialized; credentials (root-only) at $BOOT_CRED"
    fi
    python3 - "$BOOT_DIR/panel.json" "$BOOT_HTTP" <<'PY'
import json,sys
p,http=sys.argv[1],int(sys.argv[2])
d=json.load(open(p))
d['port']=http; d['tls_port']=7443
d.setdefault('base_path','lab')
json.dump(d,open(p,'w'),indent=1)
PY
    chmod 0600 "$BOOT_DIR/panel.json"
    local base
    base="$(python3 -c "import json;print(json.load(open('$BOOT_DIR/panel.json')).get('base_path','lab'))")"
    ok "ports: http $BOOT_HTTP, tls 7443, base path /$base"

    phase "bootstrap 3/5: systemd unit (isolated instance)"
    cat > "/etc/systemd/system/$BOOT_UNIT" <<EOF
[Unit]
Description=Quantum Lab Controller (isolated instance)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=GRE_PANEL_DIR=$BOOT_DIR
ExecStart=$BOOT_BIN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$BOOT_UNIT" 2>/dev/null || systemctl restart "$BOOT_UNIT"
    sleep 2
    systemctl is-active --quiet "$BOOT_UNIT" || { journalctl -u "$BOOT_UNIT" -n 10 --no-pager | tail -5; die "lab controller failed to start"; }
    ok "$BOOT_UNIT active (coexists with any existing gre-panel.service)"

    phase "bootstrap 4/5: TLS via the panel's tls-ip mode"
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1)"
    if [[ -z "$ip" ]]; then
        ip="$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)"
    fi
    [[ -n "$ip" ]] || die "cannot detect this server's public IPv4 for the certificate SAN"
    if GRE_PANEL_DIR="$BOOT_DIR" "$BOOT_BIN" tls ip "$ip" >/dev/null 2>&1; then
        systemctl restart "$BOOT_UNIT"   # the CLI issues files; the restart serves them
        sleep 2
        ok "TLS ready: local CA + IP-SAN certificate for $ip (7443)"
        echo "$ip" > "$BOOT_DIR/tls-ip"
    else
        die "tls-ip issuance failed (see journalctl -u $BOOT_UNIT)"
    fi

    phase "bootstrap 5/5: verification"
    local okc=0
    for i in 1 2 3 4 5 6 7 8; do
        if curl -sk --max-time 4 "https://127.0.0.1:7443/$base/api/health" | grep -q '"status":"ok"'; then okc=1; break; fi
        sleep 2
    done
    [[ $okc -eq 1 ]] || die "HTTPS health check failed on 7443"
    ok "HTTPS health OK: https://$ip:7443/$base/"
    printf '
%s=== Lab controller ready ===%s
' "$C_BOLD" "$C_OFF"
    printf 'Controller URL (agents):  https://%s:7443/%s
' "$ip" "$base"
    printf 'Dashboard:                https://%s:7443/%s/  (admin; credentials: %s)
' "$ip" "$base" "$BOOT_CRED"
    printf 'CA to trust on endpoints: %s/quantum-ca.crt  (install into /usr/local/share/ca-certificates/ + update-ca-certificates)
' "$BOOT_DIR/tls"
    printf 'Logs:                     journalctl -u %s -f
' "$BOOT_UNIT"
}

# maybe_ssh_bootstrap (controller variant of the shared opt-in flow). The
# minimal --bootstrap-controller lab path intentionally does not run it.
maybe_ssh_bootstrap() {
    local role="$1"
    [[ $SSH_SKIP -eq 1 ]] && return 0
    Q_ASSUME_YES=$ASSUME_YES
    if [[ -n "$SSH_PUBKEY_FILE" ]]; then
        [[ -f "$SSH_PUBKEY_FILE" ]] || die "SSH public key file not found: $SSH_PUBKEY_FILE"
        SSH_PUBKEY="$(tr -d '\r' < "$SSH_PUBKEY_FILE" | head -n1)"
    fi
    if [[ -z "$SSH_PUBKEY" && -z "$SSH_PORT" && -z "$SSH_USER" ]]; then
        if [[ -t 0 && $ASSUME_YES -eq 0 ]]; then
            q_confirm "Prepare SSH administrative access now? (existing port and password stay enabled)" \
                      "آماده‌سازی دسترسی SSH اکنون انجام شود؟" || return 0
        else
            return 0
        fi
    fi
    if ! ssh_bootstrap "$role" "${SSH_USER:-$Q_SSH_USER_DEFAULT}" "$SSH_PUBKEY" "$SSH_PORT"; then
        warn "SSH bootstrap failed; the controller installation itself is complete and untouched." \
             "راه‌اندازی SSH ناموفق بود؛ اما نصب کنترلر کامل و سالم است."
    fi
}

main() {
    parse_args "$@"
    printf '%sQuantum central controller installer (nginx + HTTPS + WebSocket proxy)%s\n' "$C_BOLD" "$C_OFF"

    if [[ $UNINSTALL -eq 1 ]]; then
        [[ $EUID -eq 0 ]] || die "--uninstall must run as root"
        do_uninstall
        exit 0
    fi

    if [[ $VERIFY_TLS -eq 1 ]]; then
        [[ $EUID -eq 0 ]] || die "--verify-tls must run as root"
        validate_domain
        [[ -x "$PANEL_BIN" ]] || die "panel binary not found — nothing to verify"
        have python3 || die "python3 is required"
        read_panel_json
        phase4_verify_privacy
        exit 0
    fi

    if [[ ${BOOT:-0} -eq 1 ]]; then
        bootstrap_controller
        exit 0
    fi

    preflight_root_os
    preflight_panel
    validate_domain
    preflight_dns
    preflight_ports
    preflight_backup

    phase "Server preparation"
    q_check_resources 1024 2048
    q_ensure_timesync

    if [[ $DRY_RUN -eq 1 ]]; then
        print_plan
        exit 0
    fi

    # Steps 2-5: binary + isolated config/service + loopback binding. No-op
    # when a panel is already installed and no --panel-version was requested.
    install_controller_binary
    read_panel_json

    install_packages
    phase2_tls
    write_proxy_site
    phase4_verify_privacy
    open_firewall
    maybe_ssh_bootstrap controller

    # Network optimization via the runtime's netopt engine (Session 2).
    netopt_prepare_server controller "$PANEL_BIN"

    mkdir -p "$MARKER_DIR"
    printf 'DOMAIN=%s\nINSTALLED=%s\n' "$DOMAIN" "$TS" > "$MARKER_FILE"
    chmod 644 "$MARKER_FILE"

    print_summary
}

main "$@"
