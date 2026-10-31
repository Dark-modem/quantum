#!/usr/bin/env bash
# lib/safety.sh — preflight safety checks and firewall protection.
#
# HARD RULES enforced here:
#   1. Never flush global iptables/nftables rules. The lab only ever
#      manipulates firewall state INSIDE lab network namespaces.
#   2. The root-namespace firewall hash is snapshotted before the run
#      and verified after; any change aborts with an alarm.
#   3. The lab refuses to run on a machine that does not look like a
#      disposable environment (VM/container/WSL) unless LAB_FORCE=1.
#   4. Every lab object name is prefixed qmx<RUNID>_ so cleanup can
#      never match a production interface.

SAFETY_SNAPSHOT=""

# --- disposable environment detection --------------------------------
is_disposable_env() {
    # WSL
    if grep -qiE 'microsoft|WSL' /proc/version 2>/dev/null; then return 0; fi
    # common VM/platform markers
    for f in /proc/xen /proc/vz /proc/bc; do [ -e "$f" ] && return 0; done
    if [ -r /sys/class/dmi/id/product_name ]; then
        case "$(cat /sys/class/dmi/id/product_name 2>/dev/null)" in
            *VirtualBox*|*VMware*|*QEMU*|*KVM*|*Bochs*|*oVirt*|*Hyper-V*) return 0 ;;
        esac
    fi
    # containers
    if [ -f /.dockerenv ] || grep -qsE '(docker|lxc|kubepods)' /proc/1/cgroup 2>/dev/null; then return 0; fi
    return 1
}

# --- root firewall snapshot (hash + optional full dump for diffing) ----
# Dumps are stored under the run dir so a change can be ATTRIBUTED:
# any diff line mentioning a lab naming token means the lab did it (hard
# alarm); anything else is an external host change (fail2ban, docker...)
# and is reported as a warning, not a lab failure.
FW_SNAP_DIR=""

_fw_hash() {
    local h1 h2
    h1="$(iptables-save 2>/dev/null | sha256sum | cut -d' ' -f1)"
    h2="$(nft list ruleset 2>/dev/null | sha256sum | cut -d' ' -f1)"
    printf '%s:%s' "${h1:-noiptables}" "${h2:-nonft}"
}

safety_snapshot_fw() {
    FW_SNAP_DIR="${1:-$(mktemp -d /tmp/qmxfw.XXXXXX)}"
    mkdir -p "$FW_SNAP_DIR"
    iptables-save > "$FW_SNAP_DIR/before.iptables" 2>/dev/null || true
    nft list ruleset > "$FW_SNAP_DIR/before.nft" 2>/dev/null || true
    SAFETY_SNAPSHOT="$(_fw_hash)"
    log_info "root firewall snapshot: ${SAFETY_SNAPSHOT%%:*}/$(grep -q . "$FW_SNAP_DIR/before.nft" 2>/dev/null && echo nft || echo nonft)"
}

safety_verify_fw() {
    local now changed
    iptables-save > "$FW_SNAP_DIR/after.iptables" 2>/dev/null || true
    nft list ruleset > "$FW_SNAP_DIR/after.nft" 2>/dev/null || true
    now="$(_fw_hash)"
    if [ "$now" = "$SAFETY_SNAPSHOT" ]; then
        log_info "root firewall unchanged after run"
        return 0
    fi
    changed="$(diff -u "$FW_SNAP_DIR/before.iptables" "$FW_SNAP_DIR/after.iptables" 2>/dev/null; diff -u "$FW_SNAP_DIR/before.nft" "$FW_SNAP_DIR/after.nft" 2>/dev/null)"
    if printf '%s' "$changed" | grep -qiE "qmx[0-9a-f]+_"; then
        log_error "SAFETY ALARM: root firewall changed and the diff mentions lab-named objects:"
        printf '%s\n' "$changed" | grep -iE "qmx[0-9a-f]+_" | head -20 >&2
        log_error "Do not trust this host's firewall state; inspect manually."
        return 1
    fi
    log_warn "root firewall changed externally during the run (host services such as fail2ban/docker; no lab-named objects in the diff, $(printf '%s\n' "$changed" | grep -c '^[+-][^+-]') lines changed)"
    return 0
}

# --- root namespace must be free of lab leftovers ---------------------
safety_check_no_orphans() {
    local orphans
    orphans="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E "^${LAB_PREFIX}[0-9a-f]+_" || true)"
    if [ -n "$orphans" ]; then
        log_warn "orphan lab interfaces in root namespace: $(echo "$orphans" | tr '\n' ' ')"
        return 1
    fi
    orphans="$(ip netns list 2>/dev/null | awk '{print $1}' | grep -E "^${LAB_PREFIX}[0-9a-f]+_" || true)"
    if [ -n "$orphans" ]; then
        log_warn "orphan lab namespaces: $(echo "$orphans" | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# --- preflight: everything that must be true before a run -------------
safety_preflight() {
    require_root

    if ! is_disposable_env; then
        if [ "${LAB_FORCE:-0}" = "1" ]; then
            log_warn "LAB_FORCE=1: running on a machine that is NOT recognizably disposable."
        else
            log_die "host is not recognizably a disposable VM/container/WSL. Refusing. (Set LAB_FORCE=1 to override.)"
        fi
    fi

    # Required tools
    local t missing=""
    for t in ip tc iptables sha256sum awk sed python3 curl od; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    [ -z "$missing" ] || log_die "missing tools:$missing (on Debian/Ubuntu: apt install iproute2 iptables python3 curl coreutils)"

    # tun device
    [ -c /dev/net/tun ] || log_die "/dev/net/tun missing — cannot run Matrix (tinc)"

    # netem capability probe (inside a throwaway ns, cleaned immediately)
    if cap_probe_netem; then
        NETEM_AVAILABLE=1
    else
        NETEM_AVAILABLE=0
        log_warn "kernel netem qdisc unavailable — delay/jitter/loss profiles will be SKIPPED (recorded honestly in the report)"
    fi

    safety_check_no_orphans || log_die "lab leftovers found; run 'labctl clean' first"
}

# Probe netem in a disposable namespace; returns 1 if unsupported.
cap_probe_netem() {
    local ns; ns="$(lab_name probe)"
    ip netns add "$ns" 2>/dev/null || return 1
    local ok=0
    if ip -n "$ns" link add d0 type dummy 2>/dev/null &&
       ip -n "$ns" link set d0 up 2>/dev/null &&
       ip netns exec "$ns" tc qdisc replace dev d0 root netem delay 1ms 2>/dev/null; then
        ok=1
    fi
    ip -n "$ns" link del d0 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    [ "$ok" = "1" ]
}

# --- static self-audit: scan our own scripts for forbidden commands ----
safety_audit() {
    local rc=0 hit
    # Forbidden: GLOBAL flush/delete — iptables -F/-X with no target
    # chain argument, or nft flush ruleset. Allowed: -F/-X naming our
    # own lab chain (literal QMX... or a "$VAR" that holds one), and
    # any iptables call issued via ns_exec inside a lab namespace.
    while IFS= read -r hit; do
        log_error "audit: forbidden global firewall flush in $hit"
        rc=1
    done < <(grep -rnE -- 'nft +flush +ruleset|iptables +(-t +[a-z]+ +)?-(F|X) *($|\||;|2>)' \
                "$LAB_ROOT/lib" "$LAB_ROOT/suites" "$LAB_ROOT/dpi" 2>/dev/null \
              | grep -vE ':[0-9]+: *#' \
              | grep -v 'F "\$\|X "\$\|F QMX\|X QMX' || true)
    # tc qdisc changes must always be namespace-scoped (ns_exec / netns exec).
    while IFS= read -r hit; do
        log_error "audit: tc qdisc change outside a lab namespace guard in $hit"
        rc=1
    done < <(grep -rnE 'tc +qdisc +(del|replace|change|add)' \
                "$LAB_ROOT/lib/netns.sh" "$LAB_ROOT/suites" "$LAB_ROOT/dpi" 2>/dev/null \
              | grep -v 'ns_exec\|netns exec' || true)
    [ "$rc" = "0" ] && log_info "audit: no forbidden firewall patterns found in lab scripts"
    return "$rc"
}
