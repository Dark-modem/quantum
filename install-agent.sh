#!/usr/bin/env bash
###############################################################################
# install-agent.sh — Quantum endpoint agent installer
#
# Installs the lightweight Quantum endpoint Agent (gre-agent) on an endpoint:
# downloads the gre-panel release asset for this architecture, verifies its
# SHA-256 against the release manifest, installs the binary, enrolls the
# endpoint with the central controller via `gre-panel agent enroll`, writes
# the gre-agent systemd unit (byte-identical to `gre-panel agent install`)
# and verifies the outbound connection to the controller.
#
#   sudo bash install-agent.sh --server https://controller.example:7443[/base] \
#        (--token TOKEN | --token-file FILE) \
#        [--role iran|foreign] [--name NAME] [--version latest|vX.Y.Z] \
#        [--github-token TOKEN] [--binary FILE] [--no-start] [--wait SECONDS]
#        [--force-enroll] [--check] [--rollback] [--yes]
#
# The Agent makes ONE outbound authenticated connection to the controller
# (WebSocket over the enroll base URL). No inbound listener is opened, no
# firewall rule is added or removed, no web panel, no PasarGuard Node, no
# nginx, no Docker and no database is installed.
#
# The Agent runs as root on purpose: the current agent privilege model
# manages the local quantum-matrix* systemd units, tinc and xray on the
# controller's behalf (see docs/AGENT-CONTROLLER.md). A dedicated non-root
# user would break those controller-driven operations, so none is created.
#
# Matrix independence: gre-agent.service shares no dependency with the
# quantum-matrix* units. Stopping or restarting the agent never stops the
# Matrix tunnel; this installer verifies that at the end of every run.
#
# Secrets: the enrollment token and the GitHub token are never printed,
# never logged and never written to disk by this script (the runtime stores
# its agent key at /etc/gre-panel/agent.json, mode 0600, itself).
###############################################################################
set -euo pipefail

# Shared installer helpers (bilingual output, firewall interface, SSH
# bootstrap, server preparation). Resolved next to this script; standalone
# copies fetch it from a PINNED commit (Session 4 review SSH-5): the URL is a
# fixed commit SHA — never a moving branch — and the downloaded content is
# verified against the pinned SHA-256 before it is sourced as root. To update
# the pin deliberately: change LIB_COMMIT and LIB_SHA256 together in a
# reviewed commit (the hash pins the exact lib bytes the installer trusts).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$LIB_DIR/installer-lib.sh" ]]; then
    # shellcheck source=installer-lib.sh
    source "$LIB_DIR/installer-lib.sh"
else
    LIB_COMMIT="31ad02023dfee87db37536c4321743cfc368964f"
    LIB_SHA256="565b9033f93a59f0c234bf06844319d8288807a74d2e953ca129a3a35379d807"
    LIB_URL="https://raw.githubusercontent.com/Dark-modem/quantum/${LIB_COMMIT}/installer-lib.sh"
    TMP_LIB="$(mktemp)"
    chmod 600 "$TMP_LIB"
    CURL_AUTH=()
    [[ -n "${GRE_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}" ]] && \
        CURL_AUTH=(-H "Authorization: Bearer ${GRE_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}")
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "${CURL_AUTH[@]}" "$LIB_URL" -o "$TMP_LIB" \
        || { printf 'Error: installer-lib.sh not found next to %s and cannot be downloaded.\n' "$0" >&2; exit 1; }
    got="$(sha256sum "$TMP_LIB" | cut -d' ' -f1)"
    if [[ "$got" != "$LIB_SHA256" ]]; then
        printf 'Error: downloaded installer-lib.sh does not match the pinned SHA-256.\n' >&2
        printf '  expected: %s\n  got:      %s\n' "$LIB_SHA256" "$got" >&2
        printf 'Refusing to execute unpinned code as root. Place the matching installer-lib.sh\n' >&2
        printf 'next to %s, or update LIB_COMMIT/LIB_SHA256 in a reviewed commit.\n' "$0" >&2
        rm -f "$TMP_LIB"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$TMP_LIB"
    rm -f "$TMP_LIB"
fi

###############################################################################
# Constants
###############################################################################
SCRIPT_NAME="install-agent.sh"
REPO="Dark-modem/quantum"
BIN="/usr/local/bin/gre-panel"
UNIT_DIR="/etc/systemd/system"
UNIT="gre-agent.service"
UNIT_NAME="gre-agent"
PANEL_DIR="/etc/gre-panel"                 # agent identity home (runtime contract)
AGENT_DIR="$PANEL_DIR/agent"               # installer-managed metadata home
IDENTITY="$PANEL_DIR/agent.json"           # written by `agent enroll` (0600)
MARKER="$AGENT_DIR/agent.env"              # installer metadata (no secrets)
BACKUP_DIR="/var/backups/quantum-agent"
PREV_BIN="$BACKUP_DIR/gre-panel.prev"
PREV_META="$BACKUP_DIR/gre-panel.prev.meta"
CONNECT_WAIT_DEFAULT=30

TS="$(date +%Y%m%d-%H%M%S)"
TMP=""
PHASE="startup"

# Runtime options (set by parse_args)
SERVER=""
ENROLL_TOKEN=""
TOKEN_FILE_ARG=""
ROLE=""
DISPLAY_NAME=""
REQ_VERSION="latest"
GH_TOKEN="${GRE_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
LOCAL_BINARY=""
NO_START=0
WAIT_SECS="$CONNECT_WAIT_DEFAULT"
FORCE_ENROLL=0
CHECK_ONLY=0
DO_ROLLBACK=0
ASSUME_YES=0

# SSH bootstrap + server preparation options (steps 3-8 of the owner's
# sequence; default: skipped unless options are given or the operator
# opts in interactively after the agent service is verified)
SSH_USER=""
SSH_PUBKEY=""
SSH_PUBKEY_FILE=""
SSH_PORT=""
SSH_SKIP=0

# Quanta observed along the way
WAS_INSTALLED=0
RELEASE_BASE="${QUANTUM_AGENT_RELEASE_BASE:-}"
TAG=""
ASSET=""
ARCH=""
DOWNLOADED_SHA=""
BIN_VERSION=""
INSTALLED_VERSION=""
AGENT_ID=""
MATRIX_UNITS_BEFORE=""

# Output colors
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_OFF=""
fi

###############################################################################
# Logging helpers (same shape as install-controller.sh)
###############################################################################
info()  { printf '%s[%s]%s %s\n'  "$C_BLUE"  "$PHASE" "$C_OFF" "$*"; }
ok()    { printf '%s[ok]%s %s\n'         "$C_GREEN" "$C_OFF" "$*"; }
warn()  { printf '%s[warn]%s %s\n'       "$C_YELLOW" "$C_OFF" "$*"; }
err()   { printf '%s[error]%s %s\n'      "$C_RED" "$C_OFF" "$*" >&2; }
die()   { err "$*"; printf '%sAborted.%s Nothing destructive was done beyond what was already logged.\n' "$C_BOLD" "$C_OFF" >&2; exit 1; }
phase() { PHASE="$1"; printf '\n%s==> %s%s\n' "$C_CYAN" "$*" "$C_OFF"; }

on_err() {
    local exit_code="$1" line="$2"
    printf '\n%s[error]%s install-agent.sh FAILED (exit %s) near line %s, during phase: %s\n' \
        "$C_RED" "$C_OFF" "$exit_code" "$line" "$PHASE" >&2
    printf 'Recovery hints:\n' >&2
    if [[ -f "$PREV_BIN" ]]; then
        printf '  - restore the previous agent binary:  sudo bash %s --rollback\n' "$SCRIPT_NAME" >&2
    fi
    printf '  - re-running this script is safe and idempotent.\n' >&2
    printf '  - no firewall, SSH, Matrix, nginx, Docker or PasarGuard state was touched.\n' >&2
}
trap 'on_err "$?" "$LINENO"' ERR

cleanup() {
    if [[ -n "$TMP" && -d "$TMP" ]]; then rm -rf "$TMP"; fi
}
trap cleanup EXIT

usage() {
    cat <<'USAGE'
install-agent.sh — Quantum endpoint agent installer

Usage:
  sudo bash install-agent.sh --server https://controller.example:7443[/base] \
       (--token TOKEN | --token-file FILE) \
       [--role iran|foreign] [--name NAME] [--version latest|vX.Y.Z] \
       [--github-token TOKEN] [--binary FILE] [--no-start] [--wait SECONDS] \
       [--force-enroll] [--check] [--rollback] [--yes]

Options:
  --server URL        Controller base URL, e.g. https://controller.example:7443[/base]
  --token TOKEN       One-time enrollment token minted on the controller
  --token-file FILE   Read the enrollment token from FILE (fixed to mode 600)
  --role ROLE         iran|foreign — informational only; the authoritative
                      role is the one baked into the token on the controller
  --name NAME         Display name for this endpoint (default: hostname)
  --version VER       'latest' (default) or an explicit tag, e.g. v1.27.2
  --github-token TOK  GitHub read token for the private release repo
                      (falls back to GRE_GITHUB_TOKEN / GITHUB_TOKEN /
                       /etc/gre-panel/github-token / hidden prompt)
  --binary FILE       Install a local binary instead of downloading
                      (advanced/air-gapped; verified against FILE.sha256 if present)
  --no-start          Enroll and enable, but do not start the service
  --wait SECONDS      Seconds to wait for the controller connection (default 30)
  --force-enroll      Re-enroll even if this endpoint is already enrolled
  --check             Verify prerequisites, download and SHA-256 only; change nothing
  --rollback          Restore the previous agent binary and restart the agent
  --yes               Never prompt (automation mode)

SSH administrative bootstrap (runs after the agent service is verified):
  --ssh-user USER     Dedicated admin account (default: qadmin, key-only, sudo)
  --ssh-pubkey KEY    Install this PUBLIC key (e.g. 'ssh-ed25519 AAAA… comment')
  --ssh-pubkey-file F Read the public key from F (preferred; one line)
  --ssh-port PORT     ADD this SSH port (the current port stays enabled until
                      the owner finalizes access via tools/QuantumSshKey.ps1)
  --no-ssh            Never touch SSH
  The private key never touches this server: generate it on the owner's
  workstation (tools/QuantumSshKey.ps1) and pass only the .pub file here.

Environment:
  GRE_AGENT_ENROLL_TOKEN            enrollment token (alternative to --token)
  GRE_GITHUB_TOKEN / GITHUB_TOKEN   GitHub read token
  QUANTUM_AGENT_RELEASE_BASE        test/mirror base URL for release assets
  GRE_PANEL_ALLOW_UNVERIFIED_UPDATE=1  skip manifest enforcement (not recommended)
USAGE
    exit 0
}

have() { command -v "$1" >/dev/null 2>&1; }

confirm() { # confirm "question" -> 0 if yes
    local reply
    [[ $ASSUME_YES -eq 1 ]] && return 0
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# write_atomic DEST < content : write stdin to DEST atomically (temp + mv)
write_atomic() {
    local dest="$1" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dest"
}

# read_secret PROMPT -> hidden read from the terminal (prompt on stderr)
read_secret() {
    local secret
    read -r -s -p "$1" secret || true
    printf '\n' >&2
    printf '%s' "$secret"
}

###############################################################################
# JSON probing without jq (flat runtime files; parsing is best-effort by
# design — the runtime owns these files, the installer only reads them)
###############################################################################
json_string_field() { # json_string_field FILE KEY -> value or ""
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n1
}

###############################################################################
# Phase: argument parsing
###############################################################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)        SERVER="${2:-}"; shift 2 ;;
            --token)         ENROLL_TOKEN="${2:-}"; shift 2 ;;
            --token-file)    TOKEN_FILE_ARG="${2:-}"; shift 2 ;;
            --role)          ROLE="${2:-}"; shift 2 ;;
            --name)          DISPLAY_NAME="${2:-}"; shift 2 ;;
            --version)       REQ_VERSION="${2:-}"; shift 2 ;;
            --github-token)  GH_TOKEN="${2:-}"; shift 2 ;;
            --binary)        LOCAL_BINARY="${2:-}"; shift 2 ;;
            --no-start)      NO_START=1; shift ;;
            --wait)          WAIT_SECS="${2:-}"; shift 2 ;;
            --force-enroll)  FORCE_ENROLL=1; shift ;;
            --check)         CHECK_ONLY=1; shift ;;
            --rollback)      DO_ROLLBACK=1; shift ;;
            --yes|-y)        ASSUME_YES=1; shift ;;
            --ssh-user)      SSH_USER="${2:-}"; shift 2 ;;
            --ssh-pubkey)    SSH_PUBKEY="${2:-}"; shift 2 ;;
            --ssh-pubkey-file) SSH_PUBKEY_FILE="${2:-}"; shift 2 ;;
            --ssh-port)      SSH_PORT="${2:-}"; shift 2 ;;
            --no-ssh)        SSH_SKIP=1; shift ;;
            --help|-h)       usage ;;
            *) err "unknown option: $1"; usage ;;
        esac
    done

    if [[ -n "$TOKEN_FILE_ARG" ]]; then
        [[ -f "$TOKEN_FILE_ARG" ]] || die "token file not found: $TOKEN_FILE_ARG"
        [[ ! -L "$TOKEN_FILE_ARG" ]] || die "token file must not be a symlink: $TOKEN_FILE_ARG"
        local mode
        mode="$(stat -c '%a' "$TOKEN_FILE_ARG" 2>/dev/null || stat -f '%Lp' "$TOKEN_FILE_ARG")"
        if [[ "$mode" != "600" ]]; then
            warn "token file $TOKEN_FILE_ARG is mode $mode (expected 600); fixing to 600"
            chmod 600 "$TOKEN_FILE_ARG"
        fi
        ENROLL_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE_ARG")"
    fi
    [[ -z "$ENROLL_TOKEN" && -n "${GRE_AGENT_ENROLL_TOKEN:-}" ]] && ENROLL_TOKEN="$GRE_AGENT_ENROLL_TOKEN"

    if [[ -n "$ROLE" && "$ROLE" != "iran" && "$ROLE" != "foreign" ]]; then
        die "--role must be iran or foreign (the authoritative role is the one baked into the enrollment token on the controller)"
    fi
    if [[ ! "$REQ_VERSION" =~ ^(latest|v[0-9][0-9A-Za-z._-]*)$ ]]; then
        die "--version must be 'latest' or a tag like v1.27.2"
    fi
    if [[ -n "$SERVER" ]]; then
        SERVER="${SERVER%%/}"
        [[ "$SERVER" =~ ^https?://[^/]+ ]] || die "--server must be a base URL like https://controller.example:7443[/base]"
        [[ "$SERVER" == http:* ]] && warn "--server uses plain http; the WebSocket will be unencrypted (ws://). Prefer https."
    fi
    [[ "$WAIT_SECS" =~ ^[0-9]+$ ]] || die "--wait must be a number of seconds"
    if [[ -n "$LOCAL_BINARY" && "$REQ_VERSION" != "latest" ]]; then
        warn "--binary overrides --version; the local file is installed as-is."
    fi
}

# Interactive mode: prompt only for what is missing, and only on a TTY.
maybe_interactive() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    if [[ -z "$SERVER" && -t 0 ]]; then
        read -r -p "Controller URL (e.g. https://controller.example:7443[/base]): " SERVER
        SERVER="${SERVER%%/}"
    fi
    if [[ -z "$ENROLL_TOKEN" && -t 0 && $CHECK_ONLY -eq 0 ]]; then
        ENROLL_TOKEN="$(read_secret 'Enrollment token (hidden): ')"
    fi
    if [[ -z "$ROLE" && -t 0 && $CHECK_ONLY -eq 0 ]]; then
        read -r -p "Endpoint role [iran/foreign, enter = keep the token's role]: " ROLE
        if [[ -n "$ROLE" && "$ROLE" != "iran" && "$ROLE" != "foreign" ]]; then
            die "role must be iran or foreign"
        fi
    fi
}

require_inputs() {
    if [[ -z "$SERVER" && $CHECK_ONLY -eq 0 ]]; then
        err "missing --server (controller URL)"
        exit 2
    fi    # A token is only needed when this endpoint is not enrolled yet (or is
    # being re-enrolled): an already-enrolled reinstall needs no new token.
    if [[ -z "$ENROLL_TOKEN" && $CHECK_ONLY -eq 0 && ! -f "$IDENTITY" ]]; then
        err "missing enrollment token (use --token, --token-file, GRE_AGENT_ENROLL_TOKEN, or run interactively)"
        exit 2
    fi
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."
}

# maybe_ssh_bootstrap : server-side SSH administrative bootstrap (steps 3-8
# of the owner's sequence) — opt-in via --ssh-* flags, or offered
# interactively after the agent service is verified. --no-ssh always skips.
# A bootstrap failure never undoes the agent installation: the service is
# already verified and the owner's existing SSH access was never modified.
maybe_ssh_bootstrap() {
    [[ $SSH_SKIP -eq 1 || $CHECK_ONLY -eq 1 || $DO_ROLLBACK -eq 1 ]] && return 0
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
            info "SSH bootstrap skipped (pass --ssh-user/--ssh-pubkey-file/--ssh-port to enable)." \
                 "راه‌اندازی SSH رد شد (برای فعال‌سازی پارامترهای --ssh-* را بدهید)."
            return 0
        fi
    fi
    if ! ssh_bootstrap agent "${SSH_USER:-$Q_SSH_USER_DEFAULT}" "$SSH_PUBKEY" "$SSH_PORT"; then
        warn "SSH bootstrap failed; the agent installation itself is complete and untouched." \
             "راه‌اندازی SSH ناموفق بود؛ اما نصب ایجنت کامل و سالم است."
    fi
}

###############################################################################
# Phase: prerequisites
###############################################################################
check_prereqs() {
    have systemctl || die "systemd is required (no systemctl on this host)."
    [[ -d /run/systemd/system ]] || warn "systemd is not running as PID 1; service steps will fail."

    # OS support: Ubuntu 24.04 (noble) and 26.04 are the supported targets.
    # Anything else with systemd still works, but is not a supported target.
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}-${VERSION_ID:-}" in
            ubuntu-24.04|ubuntu-26.04) ok "Host OS: ${PRETTY_NAME:-Ubuntu} (supported)." ;;
            ubuntu-*)                  warn "Host OS: ${PRETTY_NAME:-Ubuntu} is not in the supported list (Ubuntu 24.04, 26.04); continuing." ;;
            *)                         warn "Host OS: ${PRETTY_NAME:-unknown} is not Ubuntu; continuing (systemd required)." ;;
        esac
    else
        warn "cannot read /etc/os-release; skipping the OS check."
    fi

    # Architecture mapping to the release asset names.
    local mach
    mach="$(uname -m)"
    case "$mach" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) die "unsupported CPU architecture: $mach (supported: x86_64/amd64, aarch64/arm64)" ;;
    esac
    ASSET="gre-panel-linux-$ARCH"
    ok "Architecture: $mach -> $ASSET"

    if ! have curl; then
        info "curl is missing; installing the minimal download dependency."
        if have apt-get; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl \
                || die "cannot install curl; install it manually and re-run."
        else
            die "curl is required to download the release asset; install it and re-run."
        fi
    fi
    have sha256sum || die "sha256sum (coreutils) is required."

    # Privilege model decision: the agent manages quantum-matrix* units, tinc,
    # xray and network state on the controller's behalf, so it must run as
    # root. A dedicated system user is intentionally NOT created — see header.
    info "Privilege model: the agent runs as root (it manages quantum-matrix units, tinc and xray for the controller); no dedicated user is created."

    if [[ -x "$BIN" ]]; then
        WAS_INSTALLED=1
        INSTALLED_VERSION="$(env -u GRE_PANEL_DIR "$BIN" version 2>/dev/null || true)"
        info "Existing gre-panel binary found${INSTALLED_VERSION:+ (version ${INSTALLED_VERSION})}."
    fi
    if systemctl list-unit-files --no-legend gre-agent.service 2>/dev/null | grep -q .; then
        info "Existing $UNIT found (upgrade path)."
    fi
    if systemctl list-unit-files --no-legend gre-panel.service 2>/dev/null | grep -q .; then
        warn "gre-panel.service exists: this host runs a controller/panel. Installing an agent on it is allowed for testing, but is not the target topology."
        confirm "Continue anyway? " || die "aborted by operator"
    fi
}

###############################################################################
# GitHub token handling (private release repository) — mirrors install.sh:
# never printed, delivered to curl via stdin config, not visible in ps.
###############################################################################
resolve_gh_token() {
    if [[ -n "$RELEASE_BASE" ]]; then
        # Test/mirror base: never send the GitHub token to a non-GitHub host.
        GH_TOKEN=""
        return 0
    fi
    if [[ -n "$GH_TOKEN" ]]; then
        [[ "$GH_TOKEN" =~ ^[A-Za-z0-9_]+$ ]] || die "GitHub token contains whitespace or invalid characters; paste the token only."
        return 0
    fi
    local tf="$PANEL_DIR/github-token"
    if [[ -f "$tf" ]]; then
        GH_TOKEN="$(tr -d '\r\n' < "$tf")"
        [[ "$GH_TOKEN" =~ ^[A-Za-z0-9_]+$ ]] || die "GitHub token file $tf contains invalid characters."
        info "Using the GitHub token already saved at $tf."
        return 0
    fi
    if [[ -n "$LOCAL_BINARY" ]]; then
        return 0   # no download will happen
    fi
    if [[ $ASSUME_YES -eq 0 && -t 0 ]]; then
        GH_TOKEN="$(read_secret 'Private repository: enter a Quantum GitHub read token (hidden): ')"
        [[ "$GH_TOKEN" =~ ^[A-Za-z0-9_]+$ ]] || die "GitHub token contains whitespace or invalid characters."
        return 0
    fi
    die "Quantum releases are private and no GitHub token was provided. Export GRE_GITHUB_TOKEN, save it at $tf (mode 600), or pass --github-token."
}

# auth_curl ARGS... : curl with the GitHub token delivered by stdin config so
# it never appears in the process list. The token is only sent when set.
auth_curl() {
    if [[ -n "$GH_TOKEN" ]]; then
        printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" |
            curl --config - "$@"
    else
        curl "$@"
    fi
}

###############################################################################
# Phase: download (release asset + checksum manifest, fail-closed)
###############################################################################
resolve_tag() {
    if [[ "$REQ_VERSION" != "latest" ]]; then
        TAG="$REQ_VERSION"
        ok "Version: $TAG"
        return 0
    fi
    if [[ -n "$RELEASE_BASE" ]]; then
        local f="$TMP/latest"
        curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 30 \
            "$RELEASE_BASE/latest" -o "$f" || die "cannot resolve latest version from $RELEASE_BASE/latest"
        TAG="$(tr -d '\r\n[:space:]' < "$f")"
        [[ "$TAG" =~ ^v[0-9][0-9A-Za-z._-]*$ ]] || die "release base returned an invalid tag: $TAG"
        ok "Version: $TAG (from $RELEASE_BASE/latest)"
        return 0
    fi
    local api="https://api.github.com/repos/$REPO/releases/latest" body
    body="$(auth_curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 60 "$api")" \
        || die "cannot resolve the latest release (GitHub API failed; check the token and network)."
    TAG="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$body" | head -n1)"
    [[ "$TAG" =~ ^v[0-9][0-9A-Za-z._-]*$ ]] || die "could not read tag_name from the GitHub API response."
    ok "Version: $TAG (latest release)"
}

download_asset() { # download_asset URL OUT MAXTIME
    local url="$1" out="$2" maxtime="$3" code rc=0
    code=$(auth_curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time "$maxtime" \
        -w '%{http_code}' "$url" -o "$out" 2> "$TMP/curl-error") || rc=$?
    if [[ $rc -eq 0 ]]; then return 0; fi
    case "$code" in
        401) err "download returned 401: invalid or expired GitHub token." ;;
        403) err "download returned 403: check token permissions, approval and API rate limits." ;;
        404) err "download returned 404: release asset missing (tag $TAG, asset ${ASSET:-?})." ;;
        000) err "cannot reach the release host (DNS, connection or TLS failure; curl exit $rc)." ;;
        *)   err "download failed (HTTP ${code:-?}, curl exit $rc): $(tail -n1 "$TMP/curl-error" 2>/dev/null || true)" ;;
    esac
    return 1
}

# verify_manifest FILE : check the downloaded binary against a sha256sum
# manifest (checksums.txt / SHA256SUMS, "<sha> *<name>" or "<sha>  <name>").
verify_manifest() {
    local manifest="$1" expected actual
    expected="$(sed -n 's/^\([0-9a-fA-F]\{64\}\)[[:space:]]\+\*\?'"$ASSET"'[[:space:]]*$/\1/p' "$manifest" | head -n1)"
    [[ -n "$expected" ]] || { err "no checksum entry for $ASSET in the manifest."; return 1; }
    if [[ "${GRE_PANEL_ALLOW_UNVERIFIED_UPDATE:-0}" == "1" ]]; then
        warn "GRE_PANEL_ALLOW_UNVERIFIED_UPDATE=1: skipping manifest enforcement."
        return 0
    fi
    actual="$(sha256sum "$TMP/$ASSET" | cut -d' ' -f1)"
    if [[ "$actual" != "${expected,,}" ]]; then
        err "SHA-256 mismatch: expected ${expected,,}, got $actual."
        return 1
    fi
    return 0
}

fetch_and_verify_binary() {
    if [[ -n "$LOCAL_BINARY" ]]; then
        [[ -f "$LOCAL_BINARY" ]] || die "local binary not found: $LOCAL_BINARY"
        cp "$LOCAL_BINARY" "$TMP/$ASSET"
        if [[ -f "$LOCAL_BINARY.sha256" ]]; then
            verify_manifest "$LOCAL_BINARY.sha256" || die "local binary failed its .sha256 verification."
            ok "Local binary verified against $LOCAL_BINARY.sha256."
        else
            warn "No .sha256 file next to --binary; checksum verification skipped (local install)."
        fi
    else
        local base
        if [[ -n "$RELEASE_BASE" ]]; then
            base="$RELEASE_BASE/$TAG"
        else
            base="https://github.com/$REPO/releases/download/$TAG"
        fi
        info "Downloading $ASSET (tag $TAG)."
        download_asset "$base/$ASSET" "$TMP/$ASSET" 300 || die "release asset download failed."
        info "Downloading the checksum manifest."
        download_asset "$base/checksums.txt" "$TMP/checksums.txt" 60 \
            || download_asset "$base/SHA256SUMS" "$TMP/checksums.txt" 60 \
            || die "checksum manifest unavailable (fail-closed: refusing an unverified binary)."
        verify_manifest "$TMP/checksums.txt" || die "SHA-256 verification failed for $ASSET."
    fi

    # Sanity: a real ELF that runs and reports its version on this host.
    [[ "$(head -c 4 "$TMP/$ASSET")" == $'\x7fELF' ]] || die "downloaded asset is not an ELF binary."
    chmod 0755 "$TMP/$ASSET"
    BIN_VERSION="$(env -u GRE_PANEL_DIR "$TMP/$ASSET" version 2>/dev/null || true)"
    [[ -n "$BIN_VERSION" ]] || die "downloaded binary does not run on this machine (wrong architecture or corrupted)."
    # The agent subcommand must exist: a binary without it falls through to
    # the full panel startup and would hang the service. `timeout` guards
    # against exactly that — a panel boot never exits on its own. The probe
    # runs against a sandboxed config dir: a non-agent binary would otherwise
    # boot the panel against the real /etc/gre-panel for up to 10s and
    # initialize its panel.json as a side effect.
    if ! timeout 10 env GRE_PANEL_DIR="$TMP/gate-sandbox" "$TMP/$ASSET" agent help >/dev/null 2>&1; then
        die "downloaded binary does not support 'gre-panel agent' (is this release built with the agent runtime?)."
    fi
    if [[ "$TAG" != "latest" && "$BIN_VERSION" != "$TAG" ]]; then
        warn "binary reports version $BIN_VERSION while the release tag is $TAG."
    fi
    DOWNLOADED_SHA="$(sha256sum "$TMP/$ASSET" | cut -d' ' -f1)"
    ok "$ASSET SHA-256 verified: $DOWNLOADED_SHA (reports version $BIN_VERSION)"
}

###############################################################################
# Phase: backup + binary install (safe upgrade, idempotent re-runs)
###############################################################################
backup_previous() {
    [[ -f "$BIN" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    chmod 0700 "$BACKUP_DIR"
    cp -f "$BIN" "$PREV_BIN.new"
    chmod 0755 "$PREV_BIN.new"
    {
        printf 'VERSION=%s\n' "${INSTALLED_VERSION:-}"
        printf 'SHA256=%s\n' "$(sha256sum "$BIN" | cut -d' ' -f1)"
        printf 'TS=%s\n' "$TS"
    } > "$PREV_META.new"
    mv -f "$PREV_BIN.new" "$PREV_BIN"
    mv -f "$PREV_META.new" "$PREV_META"
    ok "Previous binary backed up to $PREV_BIN (version ${INSTALLED_VERSION:-unknown})."
}

install_binary() {
    if [[ $WAS_INSTALLED -eq 1 ]]; then
        local current_sha
        current_sha="$(sha256sum "$BIN" | cut -d' ' -f1)"
        if [[ "$current_sha" == "$DOWNLOADED_SHA" ]]; then
            ok "Binary already at the requested version ($BIN_VERSION); no swap needed."
            return 0
        fi
    fi
    if [[ $WAS_INSTALLED -eq 1 ]] && systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
        info "Stopping the running agent for the binary swap (quantum-matrix units are NOT touched)."
        systemctl stop "$UNIT_NAME" || true
    fi
    backup_previous
    install -m 0755 "$TMP/$ASSET" "$BIN.new"
    mv -f "$BIN.new" "$BIN"
    ok "Binary installed at $BIN."
}

rollback_binary() {
    [[ -f "$PREV_BIN" ]] || { err "no previous binary to roll back to ($PREV_BIN missing)."; return 1; }
    local prev_ver
    prev_ver="$(sed -n 's/^VERSION=//p' "$PREV_META" 2>/dev/null | head -n1)"
    info "Rolling back the agent binary (previous version: ${prev_ver:-unknown})."
    systemctl stop "$UNIT_NAME" 2>/dev/null || true
    install -m 0755 "$PREV_BIN" "$BIN"
    systemctl start "$UNIT_NAME" 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet "$UNIT_NAME"; then
        ok "Rollback complete; agent active on version $(env -u GRE_PANEL_DIR "$BIN" version 2>/dev/null || echo unknown)."
        return 0
    fi
    err "agent failed to start even after rollback; inspect journalctl -u $UNIT_NAME."
    return 1
}

###############################################################################
# Phase: enrollment (runtime CLI contract: agent enroll --server --token [--name])
###############################################################################
already_enrolled() {
    [[ -f "$IDENTITY" ]] || return 1
    local id server
    id="$(json_string_field "$IDENTITY" id)"
    server="$(json_string_field "$IDENTITY" server)"
    [[ -n "$id" && -n "$server" ]] || return 1
    printf '%s' "$server"
}

do_enroll() {
    local existing
    existing="$(already_enrolled || true)"
    if [[ -n "$existing" && $FORCE_ENROLL -eq 0 ]]; then
        if [[ "$existing" == "$SERVER" ]]; then
            AGENT_ID="$(json_string_field "$IDENTITY" id)"
            ok "Already enrolled with $SERVER (agent ${AGENT_ID:0:8}…); keeping the existing identity (one-time token preserved)."
            return 0
        fi
        warn "Enrolled with a different controller ($existing); re-enrolling with $SERVER."
    fi

    info "Enrolling with the controller (the token is never printed or logged)."
    local enroll_args=(agent enroll --server "$SERVER" --token "$ENROLL_TOKEN")
    [[ -n "$DISPLAY_NAME" ]] && enroll_args+=(--name "$DISPLAY_NAME")
    local out rc=0
    # env -u GRE_PANEL_DIR: the systemd unit runs without it, so the identity
    # must land where `agent run` will look for it (/etc/gre-panel/agent.json).
    out="$(env -u GRE_PANEL_DIR "$BIN" "${enroll_args[@]}" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        # The runtime's error lines never contain the token; print them.
        printf '%s\n' "$out" >&2
        err "enrollment failed (exit $rc). Check the controller URL, that the token is unused and unexpired, and that <controller>/api/agent/enroll is reachable."
        return 1
    fi
    [[ -f "$IDENTITY" ]] || { err "enrollment reported success but $IDENTITY is missing."; return 1; }
    chmod 600 "$IDENTITY" 2>/dev/null || true
    AGENT_ID="$(json_string_field "$IDENTITY" id)"
    ok "Enrolled: agent ${AGENT_ID:0:8}… (identity stored at $IDENTITY, mode $(stat -c '%a' "$IDENTITY"))."
}

###############################################################################
# Phase: systemd unit (byte-identical to the runtime's `agent install`)
#
# Mirrors panel/agent.go agentUnitContent(exe) exactly:
#   [Unit]      Description=Quantum Panel Agent / After+Wants=network-online.target
#   [Service]   Type=simple / ExecStart=<exe> agent run / Restart=always / RestartSec=5
#   [Install]   WantedBy=multi-user.target
# No User=, no dependencies on quantum-matrix units, no invented arguments.
###############################################################################
write_unit() {
    write_atomic "$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=Quantum Panel Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN agent run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "Unit written: $UNIT_DIR/$UNIT"
}

start_service() {
    if [[ $NO_START -eq 1 ]]; then
        systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || true
        info "--no-start: unit enabled but not started. Start it with: systemctl start $UNIT_NAME"
        return 0
    fi
    systemctl enable --now "$UNIT_NAME" >/dev/null 2>&1 || {
        err "systemctl enable --now $UNIT_NAME failed."
        return 1
    }
    ok "Agent service enabled and started."
}

###############################################################################
# Phase: verification (service active, controller connection, Matrix untouched)
###############################################################################
matrix_units_snapshot() {
    systemctl list-units --all 'quantum-matrix*' --no-legend 2>/dev/null \
        | awk '{print $1, $3}' | sort || true
}

matrix_check_unchanged() {
    local after
    after="$(matrix_units_snapshot)"
    if [[ "$after" != "$MATRIX_UNITS_BEFORE" ]]; then
        warn "quantum-matrix unit states changed during installation:"
        diff <(printf '%s\n' "$MATRIX_UNITS_BEFORE") <(printf '%s\n' "$after") >&2 || true
    else
        ok "quantum-matrix units untouched by the agent installation."
    fi
}

wait_for_controller() {
    local waited=0 restarts
    while (( waited < WAIT_SECS )); do
        # timeout: a status call that never exits (broken binary, panel
        # fallback) must not hang the installer.
        if timeout 10 env -u GRE_PANEL_DIR "$BIN" agent status 2>/dev/null | grep -q '"connected"[[:space:]]*:[[:space:]]*true'; then
            ok "Connected to the controller (outbound WebSocket verified)."
            return 0
        fi
        # A binary that exits right after start crash-loops under
        # Restart=always; detect it instead of waiting out the window.
        restarts="$(systemctl show -p NRestarts --value "$UNIT_NAME" 2>/dev/null || echo 0)"
        if (( restarts >= 3 )); then
            err "agent is crash-looping ($restarts restarts); see journalctl -u $UNIT_NAME."
            return 1
        fi
        sleep 2; waited=$((waited + 2))
    done
    warn "Not connected after ${WAIT_SECS}s. The agent keeps retrying with backoff (2s→120s)."
    warn "Check: is the controller reachable from this host? Is the enrollment valid? Then: journalctl -u $UNIT_NAME -f"
    return 0
}

verify_install() {
    if ! systemctl is-active --quiet "$UNIT_NAME"; then
        err "$UNIT_NAME is not active."
        return 1
    fi
    ok "$UNIT_NAME is active."
    if [[ $NO_START -eq 0 ]]; then
        if ! wait_for_controller; then
            systemctl is-active --quiet "$UNIT_NAME" || { err "$UNIT_NAME died during verification."; return 1; }
            return 1
        fi
        matrix_check_unchanged
    fi
    return 0
}

###############################################################################
# Phase: status summary (no tokens, no keys — agent ID prefix only)
###############################################################################
show_status() {
    local role_note=""
    [[ -n "$ROLE" ]] && role_note="$ROLE"
    printf '\n%s==================================================%s\n' "$C_BOLD" "$C_OFF"
    printf '%s[OK]%s Quantum endpoint agent installed.\n' "$C_GREEN" "$C_OFF"
    printf 'Agent ID:     %s\n' "${AGENT_ID:-$(json_string_field "$IDENTITY" id)}"
    printf 'Controller:   %s\n' "$SERVER"
    printf 'Role:         %s\n' "${role_note:-(stored in the enrollment token)}"
    printf 'Version:      %s\n' "${BIN_VERSION:-unknown}"
    printf 'Binary:       %s\n' "$BIN"
    printf 'Identity:     %s (0600)\n' "$IDENTITY"
    printf 'Service:      %s (%s)\n' "$UNIT_NAME" "$(systemctl is-active "$UNIT_NAME" 2>/dev/null || echo inactive)"
    printf 'Previous:     %s\n' "$([[ -f "$PREV_BIN" ]] && echo "$PREV_BIN (sudo bash $SCRIPT_NAME --rollback)" || echo none)"
    printf '\n'
    printf 'Logs:         journalctl -u %s -f\n' "$UNIT_NAME"
    printf 'Status:       gre-panel agent status\n'
    printf 'Remove:       sudo bash uninstall-agent.sh   (--purge for full removal)\n'
    printf '%s==================================================%s\n' "$C_BOLD" "$C_OFF"
}

write_marker() {
    mkdir -p "$AGENT_DIR"
    chmod 0700 "$AGENT_DIR"
    {
        printf '# Written by install-agent.sh at %s (no secrets in this file)\n' "$TS"
        printf 'SERVER=%s\n' "$SERVER"
        printf 'ROLE=%s\n' "$ROLE"
        printf 'VERSION=%s\n' "${BIN_VERSION:-}"
        printf 'ASSET_SHA256=%s\n' "$DOWNLOADED_SHA"
        printf 'ARCH=%s\n' "$ARCH"
    } > "$MARKER.tmp"
    chmod 0600 "$MARKER.tmp"
    mv -f "$MARKER.tmp" "$MARKER"
}

###############################################################################
# main
###############################################################################
main() {
    parse_args "$@"

    if [[ $DO_ROLLBACK -eq 1 ]]; then
        PHASE="rollback"
        require_root
        if rollback_binary; then exit 0; else exit 1; fi
    fi

    maybe_interactive
    require_inputs

    phase "prerequisites"
    require_root
    check_prereqs
    if [[ $CHECK_ONLY -eq 0 ]]; then
        MATRIX_UNITS_BEFORE="$(matrix_units_snapshot)"
    fi

    phase "server preparation"
    q_check_resources 512 2048
    q_ensure_timesync
    netopt_prepare_server agent

    TMP="$(mktemp -d /tmp/quantum-agent.XXXXXX)"
    chmod 700 "$TMP"

    phase "download and verify"
    if [[ -n "$LOCAL_BINARY" ]]; then
        TAG="$REQ_VERSION"   # no release resolution for a local file
    else
        resolve_gh_token
        resolve_tag
    fi
    fetch_and_verify_binary

    if [[ $CHECK_ONLY -eq 1 ]]; then
        ok "Check-only mode: download, ELF sanity and SHA-256 verification succeeded."
        ok "Asset: $ASSET  tag: $TAG  sha256: $DOWNLOADED_SHA  version: ${BIN_VERSION:-?}"
        printf 'Nothing was installed, enrolled or started.\n'
        exit 0
    fi

    phase "backup and install binary"
    install_binary

    phase "enrollment"
    do_enroll

    phase "systemd service"
    write_unit
    start_service

    phase "verification"
    if ! verify_install; then
        if [[ -f "$PREV_BIN" ]]; then
            warn "installation verification failed; attempting automatic rollback."
            if rollback_binary; then
                die "installation rolled back to the previous agent version; investigate and retry."
            fi
        fi
        die "installation verification failed."
    fi

    maybe_ssh_bootstrap

    write_marker
    show_status
}

main "$@"
