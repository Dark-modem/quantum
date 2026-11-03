#!/usr/bin/env bash
###############################################################################
# installer-lib.sh — shared Quantum installer helpers
#
# Sourced by install-controller.sh and install-agent.sh. Never executed
# directly. Keep every function prefixed q_/fw_/ssh_ so both installers can
# share one implementation.
#
# Sections:
#   1. Bilingual output (English + Persian) and traps
#   2. Environment: root, OS, architecture, resources
#   3. Atomic file writes and backups
#   4. Firewall interface  — Session 1 integration point (additive only)
#   5. Network optimization interface — Session 2 integration point (stub)
#   6. SSH administrative bootstrap (the owner's 11-step sequence, server
#      side: steps 3-8; steps 9-11 are client-side via tools/QuantumSshKey.ps1
#      and the quantum-ssh-finalize helper this section stages)
#
# Hard rules enforced throughout:
#   - never lock the owner out: the pre-existing SSH port and password login
#     stay enabled until the owner finalizes through PROVEN new access;
#   - firewall changes are additive and ownership-tagged: no reset, no
#     flush, no disable, no rules for ports this installer does not own;
#   - private keys are never generated, stored or transported here — only
#     the owner's PUBLIC key is installed, and only on explicit request.
###############################################################################

# ---------------------------------------------------------------------------
# 1. Bilingual output
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    Q_RED=$'\033[1;31m'; Q_GREEN=$'\033[1;32m'; Q_YELLOW=$'\033[1;33m'
    Q_BLUE=$'\033[1;34m'; Q_CYAN=$'\033[1;36m'; Q_BOLD=$'\033[1m'
    Q_DIM=$'\033[2m';    Q_OFF=$'\033[0m'
else
    Q_RED=""; Q_GREEN=""; Q_YELLOW=""; Q_BLUE=""; Q_CYAN=""; Q_BOLD=""; Q_DIM=""; Q_OFF=""
fi

Q_PHASE="startup"

# Bilingual helpers: q_x EN [FA] — the optional Persian line prints dimmed.
q_info()  { local fa="${2:-}"; printf '%s[%s]%s %s\n' "$Q_BLUE"  "$Q_PHASE" "$Q_OFF" "$1"; [[ -n "$fa" ]] && printf '%s        %s\n' "$Q_DIM" "$fa"; return 0; }
q_ok()    { local fa="${2:-}"; printf '%s[ok]%s %s\n'         "$Q_GREEN" "$Q_OFF" "$1"; [[ -n "$fa" ]] && printf '%s      %s\n' "$Q_DIM" "$fa"; return 0; }
q_warn()  { local fa="${2:-}"; printf '%s[warn]%s %s\n'       "$Q_YELLOW" "$Q_OFF" "$1" >&2; [[ -n "$fa" ]] && printf '%s        %s\n' "$Q_DIM" "$fa" >&2; return 0; }
q_err()   { local fa="${2:-}"; printf '%s[error]%s %s\n'      "$Q_RED" "$Q_OFF" "$1" >&2; [[ -n "$fa" ]] && printf '%s         %s\n' "$Q_DIM" "$fa" >&2; return 0; }
q_phase() { Q_PHASE="$1"; printf '\n%s==> %s%s\n' "$Q_CYAN" "$1" "$Q_OFF"; [[ -n "${2:-}" ]] && printf '%s    %s%s\n' "$Q_DIM" "$2" "$Q_OFF"; return 0; }
q_die()   { q_err "$1" "${2:-}"; printf '%sAborted.%s Nothing destructive was done beyond what was already logged.\n' "$Q_BOLD" "$Q_OFF" >&2; exit 1; }

q_have() { command -v "$1" >/dev/null 2>&1; }

q_confirm() { # q_confirm "question" [fa-question] -> 0 if yes
    local reply
    [[ ${Q_ASSUME_YES:-0} -eq 1 ]] && return 0
    read -r -p "$1${2:+ / $2} [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# 2. Environment
# ---------------------------------------------------------------------------
q_require_root() {
    [[ $EUID -eq 0 ]] || q_die "Please run as root (sudo)." "لطفا با دسترسی روت اجرا کنید (sudo)."
}

# q_check_os : hard-require systemd; Ubuntu 24.04/26.04 are the supported
# targets, anything else warns but continues.
q_check_os() {
    q_have systemctl || q_die "systemd is required (no systemctl on this host)." "سیستم‌عامل باید systemd داشته باشد."
    [[ -d /run/systemd/system ]] || q_warn "systemd is not running as PID 1; service steps will fail." "systemd به‌عنوان PID 1 اجرا نمی‌شود."
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}-${VERSION_ID:-}" in
            ubuntu-24.04|ubuntu-26.04) q_ok "Host OS: ${PRETTY_NAME:-Ubuntu} (supported)." "سیستم‌عامل پشتیبانی‌شده: ${PRETTY_NAME:-Ubuntu}" ;;
            ubuntu-*)                  q_warn "Host OS: ${PRETTY_NAME:-Ubuntu} is not in the supported list (Ubuntu 24.04, 26.04); continuing." "سیستم‌عامل در فهرست پشتیبانی نیست؛ ادامه می‌دهیم." ;;
            *)                         q_warn "Host OS: ${PRETTY_NAME:-unknown} is not Ubuntu; continuing (systemd required)." "سیستم‌عامل اوبونتو نیست؛ ادامه می‌دهیم." ;;
        esac
    else
        q_warn "cannot read /etc/os-release; skipping the OS check." "خواندن /etc/os-release ممکن نشد."
    fi
}

# q_detect_arch VAR : sets VAR to amd64|arm64 and dies otherwise.
q_detect_arch() {
    local mach
    mach="$(uname -m)"
    case "$mach" in
        x86_64)  printf -v "$1" '%s' "amd64" ;;
        aarch64) printf -v "$1" '%s' "arm64" ;;
        *) q_die "unsupported CPU architecture: $mach (supported: x86_64/amd64, aarch64/arm64)" "معماری پردازنده پشتیبانی نمی‌شود: $mach" ;;
    esac
}

# q_check_resources MIN_RAM_MB MIN_DISK_MB : explicit resource gate. Warns
# below target, dies only below the hard floor (installer cannot complete).
q_check_resources() {
    local min_ram="$1" min_disk="$2" ram_mb disk_mb
    ram_mb="$(free -m 2>/dev/null | awk 'NR==2{print $2}')"
    disk_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n "$ram_mb" && "$ram_mb" -lt "$min_ram" ]]; then
        q_warn "RAM below target: ${ram_mb}MB < ${min_ram}MB (continuing)." "حافظهٔ رم کمتر از حد هدف است؛ ادامه می‌دهیم."
        [[ "$ram_mb" -lt 256 ]] && q_die "RAM critically low (${ram_mb}MB)." "حافظهٔ رم بحرانی کم است."
    fi
    if [[ -n "$disk_mb" && "$disk_mb" -lt "$min_disk" ]]; then
        q_warn "disk below target: ${disk_mb}MB free < ${min_disk}MB (continuing)." "فضای دیسک کمتر از حد هدف است؛ ادامه می‌دهیم."
    fi
    q_ok "Resources: RAM ${ram_mb:-?}MB, disk free ${disk_mb:-?}MB." "منابع کافی است: رم و دیسک."
    [[ -n "$disk_mb" && "$disk_mb" -lt 512 ]] && q_die "disk critically low (${disk_mb}MB free)." "فضای دیسک بحرانی کم است."
    return 0
}

q_ensure_timesync() {
    if systemctl is-active systemd-timesyncd >/dev/null 2>&1 || systemctl is-active chronyd >/dev/null 2>&1; then
        q_ok "Time synchronization active (TLS depends on it)." "همگام‌سازی زمان فعال است (برای TLS لازم است)."
    else
        q_warn "no active time sync (systemd-timesyncd/chronyd); TLS may fail." "همگام‌سازی زمان فعال نیست؛ ممکن است TLS شکست بخورد."
    fi
}

# ---------------------------------------------------------------------------
# 3. Atomic writes and backups
# ---------------------------------------------------------------------------
q_backup_dir() {
    local dir
    dir="$(date +%Y%m%d-%H%M%S)"
    printf '%s' "/var/backups/quantum-installer/$dir"
}

# q_backup_file FILE : one copy per file per run into the run's backup dir.
q_backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    Q_BACKUP_DIR="${Q_BACKUP_DIR:-$(q_backup_dir)}"
    mkdir -p "$Q_BACKUP_DIR" && chmod 0700 "$Q_BACKUP_DIR"
    local dest="$Q_BACKUP_DIR/$(printf '%s' "$f" | sed 's#^/##; s#/#_#g')"
    [[ -e "$dest" ]] && return 0
    cp -a "$f" "$dest"
    q_info "Backed up $f" "پشتیبان گرفته شد: $f"
}

# q_write_atomic DEST [MODE] < content
q_write_atomic() {
    local dest="$1" mode="${2:-0644}" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$dest"
}

# ---------------------------------------------------------------------------
# 4. Firewall interface — Session 1 integration point
# ---------------------------------------------------------------------------
# CONTRACT (additive, ownership-aware):
#   fw_allow_port <role> <name> <port> <proto> [limit]
#     Adds ONE allow rule for <port>/<proto>, tagged `quantum:<role>:<name>`
#     so the rule is enumerable and removable without touching anything else.
#     [limit]=ssh applies ufw's rate limiting (6 connections/30s) — good for SSH.
#   fw_has_rule <role> <name> -> 0 if the tagged rule already exists.
#   Session 1's port-management engine replaces the ufw backend by defining
#   these functions before sourcing this file (or by owning ufw itself).
# HARD RULES: never enable/disable/reset/flush the firewall here; never add
# deny rules; never touch ports not passed in. If the firewall is inactive
# we still record the rule and warn that enforcement belongs to the engine.
# Backend detection mirrors Session 1's firewall engine semantics: UFW when
# it is the active manager, otherwise an additive iptables INPUT rule owned
# by an explicit comment tag. A native nftables ruleset is left strictly
# alone (Session 1's engine refuses it too — no foreign-ruleset writes).
# A caller (the Session 1 engine) may pre-define these functions to take over.
fw_available() {
    q_have ufw && [[ "$(ufw status 2>/dev/null | awk '/^Status:/ {print $2}')" == "active" ]] && return 0
    q_have iptables && return 0
    return 1
}

fw_has_rule() {
    local tag="quantum:$1:$2"
    if q_have ufw && [[ "$(ufw status 2>/dev/null | awk '/^Status:/ {print $2}')" == "active" ]]; then
        ufw status 2>/dev/null | grep -qF "$tag"
        return
    fi
    q_have iptables || return 1
    iptables -C INPUT -p "$3" --dport "$4" -m comment --comment "$tag" -j ACCEPT 2>/dev/null
}

fw_allow_port() {
    local role="$1" name="$2" port="$3" proto="${4:-tcp}" limit="${5:-}" verb="allow" tag
    local bin="${6:-/usr/local/bin/gre-panel}"
    tag="quantum:$role:$name"
    # Preferred path: Session 1's firewall engine CLI (audited, ownership-
    # tagged, additive-only, fail-closed). Falls back to the tagged ufw /
    # iptables paths on pre-engine runtimes. Neither path resets or flushes.
    if fw_engine_available "$bin"; then
        # timeout-bounded: a pre-engine binary without the firewall
        # subcommand falls through into serve mode and never exits —
        # bounded here so the installer can fall back to the local
        # backend instead of hanging forever.
        if timeout 90 env -u GRE_PANEL_DIR "$bin" firewall apply --yes             --owner "service:quantum-$role-$name" --note "$tag"             --add "$port/$proto" >/dev/null 2>&1; then
            q_ok "Firewall rule applied via the firewall engine: $tag $port/$proto." "قانون فایروال توسط موتور اعمال شد."
            return 0
        fi
        q_warn "firewall engine declined ($port/$proto); falling back to the local backend." "موتور فایروال نپذیرفت؛ بازگشت به بک‌اند محلی."
    fi
    if ! fw_available; then
        q_warn "no active firewall manager (ufw/iptables); rule $tag recorded as pending (enforcement is owned by the firewall engine)." "مدیر فایروال فعالی یافت نشد؛ قانون $tag ثبت شد (اعمال با موتور اختصاصی است)."
        return 0
    fi
    if fw_has_rule "$role" "$name" "$proto" "$port"; then
        q_ok "Firewall rule already present: $tag ($port/$proto)." "قانون فایروال از قبل موجود است."
        return 0
    fi
    if q_have ufw && [[ "$(ufw status 2>/dev/null | awk '/^Status:/ {print $2}')" == "active" ]]; then
        [[ "$limit" == "limit" ]] && verb="limit"
        if ufw "$verb" "$port/$proto" comment "$tag" >/dev/null 2>&1; then
            q_ok "Firewall rule added (additive ufw): $tag $port/$proto${limit:+ (rate-limited)}." "قانون فایروال اضافه شد (ufw افزودنی)."
        else
            q_warn "could not add ufw rule $tag ($port/$proto); continuing (enforcement is owned by the firewall engine)." "افزودن قانون ufw ناموفق بود؛ ادامه می‌دهیم."
        fi
        return 0
    fi
    # iptables fallback: additive ACCEPT into INPUT with an ownership comment,
    # matching Session 1's engine rules (no flushes, no policy changes).
    if iptables -I INPUT -p "$proto" --dport "$port" -m comment --comment "$tag" -j ACCEPT >/dev/null 2>&1; then
        q_ok "Firewall rule added (additive iptables): $tag $port/$proto." "قانون فایروال اضافه شد (iptables افزودنی)."
    else
        q_warn "could not add iptables rule $tag ($port/$proto); continuing (enforcement is owned by the firewall engine)." "افزودن قانون iptables ناموفق بود؛ ادامه می‌دهیم."
    fi
    return 0
}

# fw_remove_port <role> <name> <port> <proto> : remove exactly the rule that
# fw_allow_port added (same ownership tag) — the additive-rollback counterpart.
# Used when an SSH bootstrap fails after opening its own door, so a failed run
# never leaves a firewall door behind. The tag is the match key: rules this
# installer does not own are never touched.
fw_remove_port() {
    local role="$1" name="$2" port="$3" proto="${4:-tcp}" tag
    tag="quantum:$role:$name"
    fw_available || return 0
    if q_have ufw && [[ "$(ufw status 2>/dev/null | awk '/^Status:/ {print $2}')" == "active" ]]; then
        ufw status 2>/dev/null | grep -qF "$tag" || return 0
        ufw delete allow "$port/$proto" >/dev/null 2>&1 || true
        q_info "Firewall rule removed (additive rollback): $tag $port/$proto." "قانون فایروال حذف شد (بازگردانی افزودنی)."
        return 0
    fi
    if q_have iptables; then
        iptables -C INPUT -p "$proto" --dport "$port" -m comment --comment "$tag" -j ACCEPT 2>/dev/null || return 0
        iptables -D INPUT -p "$proto" --dport "$port" -m comment --comment "$tag" -j ACCEPT >/dev/null 2>&1 || true
        q_info "Firewall rule removed (additive rollback): $tag $port/$proto." "قانون فایروال حذف شد (بازگردانی افزودنی)."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 5. Network optimization interface — Session 2 integration point (stub)
# ---------------------------------------------------------------------------
# Session 2's network optimization engine lives in the runtime:
#   gre-panel netopt {detect,plan,apply,status,rollback,revert,apply-nic}
# The installer NEVER touches sysctl itself — it only invokes the engine for
# this role. On pre-engine binaries the hook degrades to an explicit warning,
# never a silent no-op. Called AFTER the role's service is verified, so the
# binary under test is the one doing the tuning.
# GRE_NO_NETOPT=1 (or the installers' --no-netopt) skips the engine entirely.
netopt_prepare_server() { # netopt_prepare_server <role: controller|agent> [binary]
    local role="$1" bin="${2:-/usr/local/bin/gre-panel}" out rc=0
    if [[ "${GRE_NO_NETOPT:-0}" == "1" ]]; then
        q_info "Network optimization skipped (--no-netopt)." "بهینه‌سازی شبکه رد شد."
        return 0
    fi
    # Presence check: the subcommand's usage output. Captured (not piped into
    # grep) so pipefail cannot turn the engine's own exit code into a false
    # "engine missing".
    local probe
    probe="$(env -u GRE_PANEL_DIR "$bin" netopt 2>&1 || true)"
    if [[ ! -x "$bin" ]] || [[ "$probe" != *"Usage: gre-panel netopt"* ]]; then
        q_warn "netopt engine not available in this runtime build; no tuning was applied." \
               "موتور بهینه‌سازی در این بیلد موجود نیست؛ هیچ تنظیمی اعمال نشد."
        return 0
    fi
    q_info "Network optimization engine detected — measuring this host." "موتور بهینه‌سازی شناسایی شد — اندازه‌گیری میزبان."
    out="$(env -u GRE_PANEL_DIR "$bin" netopt plan --role "$role" --justify "quantum-installer:server-preparation" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    if [[ $rc -ne 0 ]]; then
        # Measure-first policy: the engine refuses on hosts with unreadable
        # facts (some virtualizations). That is the engine working, not a
        # wiring failure — and the installer never tunes by itself.
        q_warn "netopt declined to plan on this host (rc=$rc); no tuning applied." \
               "موتور به دلیل نبود اطلاعات سخت‌افزاری از طراحی سر باز زد؛ تنظیمی اعمال نشد."
        return 0
    fi
    rc=0
    out="$(env -u GRE_PANEL_DIR "$bin" netopt apply --role "$role" --justify "quantum-installer:server-preparation" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    if [[ $rc -eq 0 ]]; then
        env -u GRE_PANEL_DIR "$bin" netopt status || true
        q_ok "Network optimization applied and owned by the netopt engine (rollback: gre-panel netopt rollback)." \
             "بهینه‌سازی اعمال شد؛ بازگردانی: gre-panel netopt rollback"
    else
        q_warn "netopt apply failed (rc=$rc); no tuning applied by the installer." \
               "اعمال بهینه‌سازی ناموفق بود؛ نصاب خودش هیچ تنظیمی نمی‌کند."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 5b. Firewall engine readiness (Session 1 integration point)
# ---------------------------------------------------------------------------
# Session 1's engine ships as runtime Go code (fwPlanAddOwner/fwApply/
# fwTeardownOwner + the QUANTUM_FW chain and quantum:<owner> tags). Until the
# runtime exposes a firewall CLI, the installer keeps its ufw path — which
# already conforms to the engine's contract (additive-only, ownership
# comments, no forbidden operations) — and records the engine's registry file
# when present. fw_engine_available reports honestly what the installer can
# drive TODAY.
fw_engine_available() { # 0 only when the runtime exposes the Session 1 firewall CLI
    local bin="${1:-/usr/local/bin/gre-panel}" probe
    [[ -x "$bin" ]] || return 1
    # timeout-bounded, and the bound is NOT arbitrary: the engine bounds
    # every subprocess at 15s (fwRun), so a healthy-but-slow host finishes
    # `firewall detect` within ~45s worst case. 60s covers that while
    # converting the one REAL hang — a PRE-ENGINE binary whose CLI switch
    # has no firewall case and which falls through into serve mode and
    # never exits — into a bounded "engine unavailable" answer.
    probe="$(timeout 60 env -u GRE_PANEL_DIR "$bin" firewall detect 2>&1 || true)"
    [[ "$probe" == *'"backend"'* ]]
}

# ---------------------------------------------------------------------------
# 6. SSH administrative bootstrap (server side of the owner's sequence)
# ---------------------------------------------------------------------------
Q_SSH_USER_DEFAULT="qadmin"
Q_SSH_DROPIN="/etc/ssh/sshd_config.d/60-quantum-ssh.conf"
Q_SSH_FINALIZE_BIN="/usr/local/sbin/quantum-ssh-finalize"

# ssh_listening_ports : ports sshd is bound to right now (source of truth for
# "the owner's current SSH port"). Falls back to config-declared ports, then 22.
ssh_listening_ports() {
    local ports
    ports="$(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}')"
    if [[ -z "$ports" ]]; then
        ports="$(grep -hsE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}')"
    fi
    [[ -z "$ports" ]] && ports="22"
    printf '%s\n' "$ports" | sort -n | uniq
}

# ssh_prepare_account USER : create the dedicated admin account idempotently.
# Passwordless sudo: the account is key-only (no password exists to attack)
# and the owner must never be locked out of privilege escalation.
ssh_prepare_account() {
    local user="$1"
    # Minimal/minimal-cloud images may lack the sudo group or /etc/sudoers.d.
    getent group sudo >/dev/null 2>&1 || groupadd -f sudo
    if id "$user" >/dev/null 2>&1; then
        q_ok "Admin account already exists: $user" "کاربر مدیریتی از قبل موجود است."
    else
        useradd -m -s /bin/bash "$user" || q_die "cannot create user $user" "ساخت کاربر $user ناموفق بود."
        q_ok "Admin account created: $user (key-only, sudo enabled)" "کاربر مدیریتی ساخته شد (ورود فقط با کلید، دسترسی sudo)."
    fi
    id -nG "$user" | grep -qw sudo || usermod -aG sudo "$user"
    install -d -m 0755 /etc/sudoers.d
    if ! grep -qs "^$user ALL=(ALL) NOPASSWD:ALL$" /etc/sudoers.d/90-quantum-"$user" 2>/dev/null; then
        printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" | q_write_atomic "/etc/sudoers.d/90-quantum-$user" 0440
    fi
    if ! visudo -c >/dev/null 2>&1; then
        rm -f "/etc/sudoers.d/90-quantum-$user"
        q_die "sudoers validation failed; removed the quantum sudoers drop-in." "اعتبارسنجی sudoers ناموفق بود؛ فایل حذف شد."
    fi
    q_ok "Sudo ready for $user (NOPASSWD, key-only account)." "دسترسی sudo برای کاربر آماده است."
}

# ssh_install_pubkey USER PUBKEY : append the owner's PUBLIC key idempotently.
# Validates the key shape; never touches other lines; never accepts a private
# key blob. Returns 1 on a bad key (caller decides severity).
ssh_install_pubkey() {
    local user="$1" key="$2" ssh_dir auth
    key="$(printf '%s' "$key" | tr -d '\r' | awk '{$1=$1};1')"
    case "$key" in
        "ssh-ed25519 "*|"ssh-rsa "*|"ecdsa-sha2-"*|"sk-ssh-ed25519@"*|"sk-ecdsa-sha2-"*) : ;;
        *) q_err "not a public key (expecting 'ssh-ed25519 AAAA… comment')" "این یک کلید عمومی معتبر نیست."; return 1 ;;
    esac
    ssh_dir="$(getent passwd "$user" | cut -d: -f6)/.ssh"
    [[ -d "$ssh_dir" ]] || mkdir -m 700 "$ssh_dir"
    chown "$user:$user" "$ssh_dir"
    chmod 700 "$ssh_dir"
    auth="$ssh_dir/authorized_keys"
    q_backup_file "$auth"
    touch "$auth" && chown "$user:$user" "$auth" && chmod 600 "$auth"
    if grep -qxF "$key" "$auth"; then
        q_ok "Public key already installed (no duplicate)." "کلید عمومی از قبل نصب است (بدون تکرار)."
    else
        printf '%s\n' "$key" >> "$auth"
        q_ok "Public key installed for $user." "کلید عمومی نصب شد."
    fi
}

# ssh_configure_port NEWPORT : ADD the requested port while KEEPING every
# port sshd already listens on. The drop-in is the only file touched; the
# main sshd_config and other drop-ins are never modified.
ssh_configure_port() {
    local new_port="$1" old old_ports
    [[ "$new_port" =~ ^[0-9]+$ ]] || { q_err "--ssh-port must be numeric" "پورت SSH باید عددی باشد."; return 1; }
    (( new_port >= 1 && new_port <= 65535 )) || { q_err "--ssh-port out of range" "پورت SSH خارج از محدوده است."; return 1; }
    old_ports="$(ssh_listening_ports | tr '\n' ' ')"
    if grep -qsE "(^|[[:space:]])Port[[:space:]]+$new_port([[:space:]]|$)" "$Q_SSH_DROPIN" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
        q_ok "SSH port $new_port already configured (idempotent)." "پورت SSH از قبل تنظیم شده است."
        return 0
    fi
    q_backup_file "$Q_SSH_DROPIN"
    {   echo "# Managed by the Quantum installer (ownership: quantum:ssh). Additive only:"
        echo "# keeps the pre-existing SSH port(s) until the owner finalizes access."
        echo "# Old port(s) preserved: ${old_ports%% }"
        for old in $old_ports; do
            printf 'Port %s\n' "$old"
        done
        printf 'Port %s\n' "$new_port"
    } > "$Q_SSH_DROPIN.tmp"
    mv -f "$Q_SSH_DROPIN.tmp" "$Q_SSH_DROPIN"
    chmod 0644 "$Q_SSH_DROPIN"
    q_ok "SSH port $new_port ADDED (existing port(s) kept: ${old_ports%% })." "پورت جدید اضافه شد و پورت قبلی حفظ شد."
}

# ssh_validate : hard gate — sshd config must parse before anything reloads.
# On failure the just-written drop-in is removed so no later restart inherits
# a broken configuration.
ssh_validate() {
    install -d -m 0755 /run/sshd   # privilege separation dir: absent on minimal/container hosts
    if sshd -t 2>/tmp/q-sshd-err; then
        q_ok "sshd configuration validates." "پیکربندی sshd معتبر است."
        return 0
    fi
    q_err "sshd -t FAILED: $(tr '\n' ' ' </tmp/q-sshd-err)"
    rm -f "$Q_SSH_DROPIN"
    q_warn "quantum SSH drop-in removed; the previous sshd configuration is intact." "فایل تنظیمات کوانتوم حذف شد؛ پیکربندی قبلی سالم است."
    return 1
}

# ssh_reload : reload (never restart) after successful validation.
ssh_reload() {
    if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
        q_ok "sshd reloaded; the old SSH session and port remain fully functional." "sshd بارگذاری مجدد شد؛ پورت و نشست قبلی سالم ماند."
        return 0
    fi
    q_err "could not reload sshd (no config was broken — validate passed)." "بارگذاری مجدد sshd ناموفق بود."
    return 1
}

# ssh_socket_active : true when SSH is systemd socket-activated (Ubuntu
# 22.10+ default). In that mode sshd_config ports are NOT live listeners —
# the socket unit owns them — so a plain `systemctl reload ssh` never opens
# the new port.
ssh_socket_active() { systemctl is-active --quiet ssh.socket 2>/dev/null; }

# ssh_verify_listening PORT... : 0 when every given port has a live listener
# (held by sshd or by systemd on behalf of the socket unit).
ssh_verify_listening() {
    local p
    for p in "$@"; do
        ss -tln 2>/dev/null | awk '{print $4}' | grep -E ":${p}$" | grep -q . || return 1
    done
    return 0
}

# ssh_apply : make the validated sshd configuration effective without
# dropping the owner's session. Socket-activated systems are migrated to the
# traditional daemon (the documented Ubuntu procedure for SSH port changes);
# existing sessions survive a daemon restart, and every preserved port is
# re-verified — with a full socket rollback if anything is missing.
ssh_apply() {
    local before p
    before="$(ssh_listening_ports | tr '\n' ' ')"
    if ssh_socket_active; then
        q_info "SSH is socket-activated; migrating to the traditional daemon so the port change takes effect." "SSH در حالت سوکت است؛ برای اعمال تغییر پورت به سرویس سنتی منتقل می‌شود."
        systemctl disable --now ssh.socket >/dev/null 2>&1 || true
        install -d -m 0755 /run/sshd   # the traditional daemon needs it at start
        systemctl enable ssh.service >/dev/null 2>&1 || true
        systemctl restart ssh.service 2>/dev/null || {
            q_warn "could not start traditional sshd; restoring the socket." "اجرای سنتی ناموفق بود؛ سوکت بازگردانده می‌شود."
            systemctl enable --now ssh.socket >/dev/null 2>&1 || true
            return 1
        }
        # Every port that listened before must still listen now.
        for p in $before; do
            if ! ssh_verify_listening "$p"; then
                q_err "port $p stopped listening after the SSH migration — rolling back to the socket." "پورت $p پس از مهاجرت بسته شد — بازگشت به سوکت."
                systemctl disable --now ssh.service >/dev/null 2>&1 || true
                systemctl enable --now ssh.socket >/dev/null 2>&1 || true
                return 1
            fi
        done
        q_ok "SSH migrated to the traditional daemon; all previous ports preserved." "مهاجرت کامل شد و همهٔ پورت‌های قبلی حفظ شدند."
        return 0
    fi
    if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
        return 0
    fi
    q_err "could not reload sshd (no config was broken — validate passed)."
    return 1
}

# ssh_stage_finalize : writes the server-side finalize helper that the owner
# runs THROUGH the proven new access (client: tools/QuantumSshKey.ps1
# Complete-QuantumSsh). It disables password authentication and removes the
# pre-existing port(s) from the QUANTUM drop-in only — never the main config,
# never other drop-ins, never the new port.
ssh_stage_finalize() {
    local new_port="${1:-}"
    q_write_atomic "$Q_SSH_FINALIZE_BIN" <<EOF
#!/bin/bash
# quantum-ssh-finalize — step 10 of the owner's sequence. Run it through the
# PROVEN new SSH access (key + port). Refuses to run unless --yes is passed,
# never touches the quantum port, the main sshd_config or other drop-ins.
set -euo pipefail
[[ \${1:-} == "--yes" ]] || { echo "refusing: pass --yes after you have logged in through the NEW port and key"; exit 2; }
DROPIN="$Q_SSH_DROPIN"
NEW_PORT="${new_port:-22}"
# Port guard applied only when this bootstrap ADDED a dedicated new port;
# a pubkey-only bootstrap must not demand a session on port 22.
ENFORCE_PORT_GUARD="${new_port:+1}"
[[ -f "\$DROPIN" ]] || { echo "no quantum ssh drop-in found; nothing to do"; exit 1; }
# Technical proven-access guard (Session 4 review SSH-2): when invoked over
# SSH, the session must have arrived on the NEW port. Console sessions (no
# SSH_CONNECTION) are allowed — the owner is physically present.
if [[ "\$ENFORCE_PORT_GUARD" == "1" && -n "\${SSH_CONNECTION:-}" ]]; then
    SESSION_PORT="\$(printf '%s' "\$SSH_CONNECTION" | awk '{print \$4}')"
    if [[ "\$SESSION_PORT" != "\$NEW_PORT" ]]; then
        echo "refusing: this SSH session arrived on port \$SESSION_PORT, not the new port \$NEW_PORT." >&2
        echo "Log in through the new port and key first, then re-run this command." >&2
        exit 3
    fi
fi
cp -a "\$DROPIN" "\$DROPIN.pre-finalize"
# keep the quantum port; drop every other Port line this drop-in added.
# Anchored match (Session 4 review SSH-4): "^Port 2222\$" must not also keep
# "Port 22221".
awk -v port="\$NEW_PORT" '
    /^[[:space:]]*Port[[:space:]]/ { if (\$0 !~ ("^Port " port "\$")) next }
    { print }' "\$DROPIN" > "\$DROPIN.tmp"
printf '# Password authentication disabled by quantum-ssh-finalize (owner-requested).\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' >> "\$DROPIN.tmp"
mv -f "\$DROPIN.tmp" "\$DROPIN"
if ! sshd -t; then
    cp -a "\$DROPIN.pre-finalize" "\$DROPIN"
    echo "sshd validation failed; the previous drop-in was restored. Nothing was reloaded." >&2
    exit 1
fi
# Socket-activated SSH (Ubuntu 22.10+) needs the daemon migration, not reload.
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    systemctl enable ssh.service >/dev/null 2>&1 || true
    systemctl restart ssh.service
else
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
fi
if ! ss -tln 2>/dev/null | awk '{print \$4}' | grep -E ":\$NEW_PORT\$" | grep -q .; then
    echo "WARNING: port \$NEW_PORT is not listening; restoring the pre-finalize drop-in." >&2
    cp -a "\$DROPIN.pre-finalize" "\$DROPIN"
    systemctl restart ssh.service 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    exit 1
fi
echo "[ok] Finalized: password login disabled; only port \$NEW_PORT is served by the quantum drop-in."
echo "     Recovery: the key on port \$NEW_PORT is the only SSH access now; keep that key safe."
echo "     (فارسی): ورود با رمز غیرفعال شد؛ تنها پورت \$NEW_PORT و کلید شما باقی است — کلید را ایمن نگه دارید."
EOF
    chmod 0750 "$Q_SSH_FINALIZE_BIN"
    q_ok "Staged $Q_SSH_FINALIZE_BIN (runs only through proven new access)." "اسکریپت نهایی‌سازی آماده شد (فقط از طریق دسترسی جدید اجرا می‌شود)."
}

# ssh_print_handoff USER NEWPORT KEY_HINT : step 11 — the exact next actions.
ssh_print_handoff() {
    local user="$1" port="$2" role="${3:-endpoint}"
    printf '\n%s==================================================%s\n' "$Q_BOLD" "$Q_OFF"
    q_ok "SSH bootstrap complete — verify from your workstation now." "راه‌اندازی SSH کامل شد — اکنون از سیستم خودتان بررسی کنید."
    printf '\n1) Test the NEW access (do this before anything else):\n'
    printf '   ssh -i <private-key> -p %s %s@<server-address>\n' "$port" "$user"
    printf '\n2) Only after the test succeeds, optionally lock the old door\n   (disables password login and the old port):\n'
    printf '   PowerShell:  .\\tools\\QuantumSshKey.ps1 Complete-QuantumSsh -HostName <server> -Port %s -User %s -KeyPath <private-key>\n' "$port" "$user"
    printf '\n3) The old port and password login remain ENABLED until step 2 succeeds.\n   (پورت قبلی و ورود با رمز تا موفقیت مرحلهٔ ۲ فعال می‌مانند.)\n'
    printf '%s==================================================%s\n' "$Q_BOLD" "$Q_OFF"
}

# ssh_bootstrap ROLE USER PUBKEY NEWPORT : steps 3-8 (server side). Pubkey
# may be empty to manage only the port. Returns non-zero only if validation
# or reload failed (caller decides whether to abort the installation).
# Firewall rollback (Session 4 review SSH-3): when this call itself added the
# ssh-alt rule, any failure path removes it again — a failed bootstrap never
# leaves a firewall door it opened. A rule that already existed is left alone.
ssh_bootstrap() {
    local role="$1" user="$2" pubkey="$3" new_port="$4"
    local fw_ours=0
    q_ssh_rollback_fw() {
        [[ $fw_ours -eq 1 ]] && fw_remove_port "$role" "ssh-alt" "$new_port" tcp
        return 0
    }
    q_phase "SSH administrative bootstrap (steps 3-8)" "راه‌اندازی دسترسی مدیریتی SSH (مراحل ۳ تا ۸)"
    q_require_root
    ssh_prepare_account "$user"
    if [[ -n "$pubkey" ]]; then
        ssh_install_pubkey "$user" "$pubkey" || return 1
    else
        q_warn "no public key provided; the account is created but keyless (install a key before finalizing)." "کلید عمومی داده نشد؛ بعداً کلید را نصب کنید."
    fi
    if [[ -n "$new_port" ]]; then
        fw_has_rule "$role" "ssh-alt" tcp "$new_port" || fw_ours=1
        if ! ssh_configure_port "$new_port"; then
            q_ssh_rollback_fw
            return 1
        fi
        fw_allow_port "$role" "ssh-alt" "$new_port" tcp limit
    fi
    if ! ssh_validate; then
        q_ssh_rollback_fw
        return 1
    fi
    if ! ssh_apply; then
        q_ssh_rollback_fw
        return 1
    fi
    if [[ -n "$new_port" ]]; then
        # the HUP re-exec rebinds asynchronously — short grace window
        SSH_LISTEN_TRIES=6 ssh_verify_listening "$new_port" || {
            q_err "the new SSH port $new_port is NOT listening; existing access is untouched." "پورت جدید باز نشد؛ دسترسی قبلی سالم است."
            q_ssh_rollback_fw
            return 1
        }
    fi
    ssh_stage_finalize "$new_port"
    ssh_print_handoff "$user" "${new_port:-22}" "$role"
    return 0
}

# ---------------------------------------------------------------------------
# 7. Complete Server Setup — a numbered menu wrapping independently
#    executable phases. Every phase is idempotent, additive and reversible;
#    nothing here flushes firewall state, removes accounts, or disables
#    existing SSH access. Personal-script audit classification (node-setup/
#    setup.sh, v14.2 — the file is no longer in the workspace; classified
#    from the Session 3 installer audit record):
#      SAFE   → full backup before changes; additive ufw/iptables opens;
#               MSS clamp; per-file sysctl application with read-back.
#      MODIFY → SSH hardening (dedicated port + key-only) — reimplemented
#               here WITH verify-before-finalize and a revert tool.
#               sysctl values — taken only through Session 2's netopt engine
#               (support-checked, journalled, reversible).
#      REJECT → `ufw --force reset` + before.rules overwrite; blanket
#               MASQUERADE; systemd-resolved replacement; password-in-script
#               sudoers; hardcoded SSH key passphrase.
# ---------------------------------------------------------------------------

setup_install_role() { # defined per-installer; the lib only declares the hook
    q_die "setup_install_role must be defined by the role installer."
}

SETUP_VERIFY_UNITS=()

setup_inspect() { # Phase 0 — read-only system inspection
    q_phase "Phase 0: System inspection" "فاز ۰: بازرسی سیستم"
    q_require_root
    [[ -r /etc/os-release ]] && . /etc/os-release && q_info "OS: ${PRETTY_NAME:-unknown}" "سیستم‌عامل: ${PRETTY_NAME:-unknown}"
    q_info "Arch: $(uname -m) · Kernel: $(uname -r)" "معماری: $(uname -m) · هسته: $(uname -r)"
    q_info "CPU: $(nproc) core(s) · RAM: $(awk '/MemTotal/ {printf "%.0f MB", $2/1024}' /proc/meminfo) · Disk: $(df -h / | awk 'NR==2 {print $4" free / "$2}')" "پردازنده: $(nproc) · رم: $(awk '/MemTotal/ {printf "%.0f MB", $2/1024}' /proc/meminfo)"
    q_info "Public route: $(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1)" "مسیر عمومی: $(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1)"
    local svc
    for svc in gre-panel gre-agent gre-agent-lab quantum-matrix xray nginx docker; do
        systemctl is-active --quiet "$svc" 2>/dev/null && q_info "running service: $svc" "سرویس فعال: $svc"
    done
    q_info "listeners:" "شنونده‌ها:"
    ss -tulnp 2>/dev/null | grep -vE "127\.0\.0\.5[34]|::1|127\.0\.0\.1" | head -12
    q_info "SSH: $(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -un | tr '\n' ' ')" "SSH: $(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -un | tr '\n' ' ')"
    if q_have ufw; then q_info "ufw: $(ufw status | awk '/^Status:/ {print $2}')" "ufw: $(ufw status | awk '/^Status:/ {print $2}')"; fi
    q_info "iptables rules: $(iptables-save 2>/dev/null | wc -l)" "قوانین iptables: $(iptables-save 2>/dev/null | wc -l)"
    return 0
}

setup_backup() { # Phase 0b — backup before changes
    q_phase "Phase 0b: Backup" "فاز ۰ب: پشتیبان‌گیری"
    q_require_root
    local ts dir=/var/backups/quantum-setup
    ts="$(date +%F-%H%M%S)"; mkdir -p "$dir"
    tar -C / -czf "$dir/pre-setup-$ts.tgz" \
        etc/gre-panel etc/gre-panel-lab* etc/ssh/sshd_config \
        etc/ssh/sshd_config.d etc/nginx etc/systemd/system 2>/dev/null
    iptables-save > "$dir/iptables-$ts.txt" 2>/dev/null
    ss -tulnp > "$dir/listeners-$ts.txt" 2>/dev/null
    q_ok "Backup written: $dir/pre-setup-$ts.tgz (+ iptables/listeners snapshots)" "پشتیبان نوشته شد: $dir/pre-setup-$ts.tgz"
    SETUP_LAST_BACKUP="pre-setup-$ts"
    return 0
}

setup_ssh() { # Phase 1 — SSH security (delegates to ssh_bootstrap)
    q_phase "Phase 1: SSH security" "فاز ۱: امنیت SSH"
    local user="${SETUP_SSH_USER:-qadmin}" port="${SETUP_SSH_PORT:-}" pubkey="${SETUP_SSH_PUBKEY:-}"
    if [[ -z "$pubkey" && -n "${SETUP_SSH_PUBKEY_FILE:-}" && -f "$SETUP_SSH_PUBKEY_FILE" ]]; then
        pubkey="$(tr -d '\r\n' < "$SETUP_SSH_PUBKEY_FILE")"
    fi
    [[ -z "$port" && -n "${SETUP_SSH_PORT_FILE:-}" ]] && port="$(tr -d '\r\n' < "$SETUP_SSH_PORT_FILE" 2>/dev/null)"
    ssh_bootstrap "${SETUP_ROLE:-agent}" "$user" "$pubkey" "$port"
}

setup_firewall() { # Phase 2 — read-only inventory then engine-backed opens
    q_phase "Phase 2: Firewall and ports (read-only inventory first)" "فاز ۲: فایروال و پورت‌ها (اول فقط خواندنی)"
    q_require_root
    q_info "iptables rules: $(iptables-save 2>/dev/null | wc -l) · ufw: $(q_have ufw && ufw status | awk '/^Status:/ {print $2}' || echo absent)" "قوانین: $(iptables-save 2>/dev/null | wc -l) · ufw: $(q_have ufw && ufw status | awk '/^Status:/ {print $2}' || echo absent)"
    q_info "No rules are changed by this inventory. Opens happen through the role installers (engine-backed, ownership-tagged)." "هیچ قانونی تغییر نمی‌کند. باز کردن پورت‌ها توسط نصب‌کنندهٔ نقش انجام می‌شود (با موتور و برچسب مالکیت)."
    return 0
}

setup_verify() { # Phase 5 — post-install verification
    q_phase "Phase 5: Verification" "فاز ۵: راستی‌آزمایی"
    local fails=0
    systemctl is-active --quiet sshd || systemctl is-active --quiet ssh || { q_err "sshd not running"; fails=$((fails+1)); }
    for u in "${SETUP_VERIFY_UNITS[@]}"; do
        systemctl is-active --quiet "$u" && q_ok "$u active" "$u فعال" || { q_err "$u NOT active" "$u فعال نیست"; fails=$((fails+1)); }
    done
    q_info "listeners now:" "شنونده‌ها:"
    ss -tulnp 2>/dev/null | grep -vE "127\.0\.0\.5[34]|::1" | head -10
    [[ $fails -eq 0 ]] && q_ok "Verification passed (0 failures)" "راستی‌آزمایی موفق" || q_err "Verification had $fails failure(s)" "$fails خطا"
    return $fails
}

setup_menu() { # the numbered menu — a wrapper, never a second installer
    local role="$1"
    while true; do
        q_phase "Quantum Server Setup — role: $role" "نصب سرور Quantum — نقش: $role"
        cat <<MENU
  0) System inspection (read-only)         بازرسی سیستم
  1) Backup before changes                 پشتیبان‌گیری
  2) SSH security (key + qadmin + port)    امنیت SSH
  3) Firewall inventory (read-only)        فایروال (فقط خواندنی)
  4) Install role ($role)                  نصب نقش
  5) Network optimization (plan/confirm)   بهینه‌سازی شبکه
  6) Verification                          راستی‌آزمایی
  q) Quit                                  خروج
MENU
        local choice=""
        read -r -p "Select / انتخاب: " choice
        case "$choice" in
            0) setup_inspect ;;
            1) setup_backup ;;
            2) setup_ssh ;;
            3) setup_firewall ;;
            4) setup_install_role "$role" ;;
            5) netopt_prepare_server "$role" "${SETUP_BIN:-/usr/local/bin/gre-panel}" ;;
            6) setup_verify ;;
            q|Q) return 0 ;;
            *) q_warn "unknown choice: $choice" "انتخاب نامعتبر" ;;
        esac
    done
}
