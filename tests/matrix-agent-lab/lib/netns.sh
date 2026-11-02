#!/usr/bin/env bash
# lib/netns.sh — lab topology lifecycle (network namespaces + veths).
#
# Topology per run (everything prefixed qmx<RUNID>_, 6-hex runid keeps
# interface names within the 15-char kernel limit):
#
#   ns qmxRID_client          ns qmxRID_iran                 ns qmxRID_kharej
#     wan0 ──── veth ──── wan0 ─┤ ├─ tlink ─── veth ──── tlink
#   10.100.0.2          10.100.0.1  10.200.0.1          10.200.0.2
#                                matrix (tinc tun, 172.16.99.1)  matrix (172.16.99.2)
#
# wan0 (client↔iran) stands for the *client-facing* half of the Iranian
# physical NIC; tlink (iran↔kharej) carries ONLY Matrix transport bytes.
# netem shaping is applied to the egress qdisc of tlink inside each
# namespace, so client traffic is never shaped.

NETEM_AVAILABLE=0

ns_exec() { ip netns exec "$1" "${@:2}"; }

# NOTE: engine processes are launched with the pattern
#   ip netns exec <ns> unshare -m ... sh -c '... exec tincd' &
# (see lib/engine.sh). Backgrounding the SIMPLE COMMAND keeps $! equal to
# the real tincd pid; backgrounding a wrapper function would give a
# throwaway subshell pid and break kill/monitoring.

netns_up() {
    local ns_i ns_k ns_c
    ns_i="$(lab_name iran)"; ns_k="$(lab_name kharej)"; ns_c="$(lab_name client)"

    ip netns add "$ns_i" && ip netns add "$ns_k" && ip netns add "$ns_c"

    # client <-> iran (wan0 pair)
    ip link add "$(lab_name irw)" type veth peer name "$(lab_name cli)"
    ip link set "$(lab_name irw)" netns "$ns_i" name wan0
    ip link set "$(lab_name cli)" netns "$ns_c" name wan0

    # iran <-> kharej (tlink pair)
    ip link add "$(lab_name irt)" type veth peer name "$(lab_name kht)"
    ip link set "$(lab_name irt)" netns "$ns_i" name tlink
    ip link set "$(lab_name kht)" netns "$ns_k" name tlink

    for ns in "$ns_i" "$ns_k" "$ns_c"; do ns_exec "$ns" ip link set lo up; done

    ns_exec "$ns_i" ip addr add "$IRAN_WAN_IP/30"    dev wan0
    ns_exec "$ns_c" ip addr add "$CLIENT_WAN_IP/30"  dev wan0
    ns_exec "$ns_i" ip addr add "$IRAN_TLINK_IP/30"  dev tlink
    ns_exec "$ns_k" ip addr add "$KHAREJ_TLINK_IP/30" dev tlink

    ns_exec "$ns_i" ip link set wan0 up
    ns_exec "$ns_c" ip link set wan0 up
    ns_exec "$ns_i" ip link set tlink up
    ns_exec "$ns_k" ip link set tlink up

    ns_exec "$ns_c" ip route replace default via "$IRAN_WAN_IP"

    # Kharej reaches the iran side only through the Matrix interface;
    # the plain L3 path 10.200.0.x is used ONLY by the tinc transport.
    ns_exec "$ns_k" ip route add "$IRAN_TLINK_IP/32" dev tlink 2>/dev/null || true

    # The iran side must forward payload packets wan0 -> matrix
    # (this is exactly what matrix.sh enables on the Iranian node).
    ns_exec "$ns_i" sysctl -qw net.ipv4.ip_forward=1
    log_info "topology up: $(lab_name client) / $(lab_name iran) / $(lab_name kharej)"
}

# Apply a netem profile to the tunnel veth egress inside both namespaces.
# Args: <scenario-name> then tc netem args, e.g.: netem_apply lossy delay 20ms loss 2%
netem_apply() {
    local label="$1"; shift
    [ "$NETEM_AVAILABLE" = "1" ] || { log_warn "netem unavailable, profile '$label' ignored"; return 2; }
    local ns_i ns_k
    ns_i="$(lab_name iran)"; ns_k="$(lab_name kharej)"
    # tc on qdisc of tlink — inside lab namespaces only.
    ns_exec "$ns_i" tc qdisc replace dev tlink root netem "$@" || return 1
    ns_exec "$ns_k" tc qdisc replace dev tlink root netem "$@" || return 1
    log_info "netem profile '$label' applied on both tunnel egress directions: $*"
}

netem_clear() {
    [ "$NETEM_AVAILABLE" = "1" ] || return 0
    local ns_i ns_k
    ns_i="$(lab_name iran)"; ns_k="$(lab_name kharej)"
    ns_exec "$ns_i" tc qdisc del dev tlink root 2>/dev/null || true
    ns_exec "$ns_k" tc qdisc del dev tlink root 2>/dev/null || true
}

# Hold the tunnel link down for N seconds (recovery test), then restore.
# Uses link state — no firewall changes anywhere.
link_blackout() {
    local secs="${1:-$BLACKOUT_S}"
    local ns_i; ns_i="$(lab_name iran)"
    log_info "blackout: tunnel link down for ${secs}s"
    ns_exec "$ns_i" ip link set tlink down
    sleep "$secs"
    ns_exec "$ns_i" ip link set tlink up
    log_info "blackover done, tunnel link restored"
}

# --- teardown ----------------------------------------------------------
# Kill all processes that live in a lab namespace, then delete it.
netns_teardown_run() {
    local rid="${1:-$RUNID}" ns
    if [ -z "$rid" ]; then
        log_warn "no RUNID — nothing to tear down"
        return 0
    fi
    while read -r ns; do
        [ -n "$ns" ] || continue
        local pids
        pids="$(ip netns pids "$ns" 2>/dev/null || true)"
        if [ -n "$pids" ]; then
            log_info "stopping pids in $ns: $(echo "$pids" | tr '\n' ' ')"
            kill $pids 2>/dev/null || true
            sleep 1
            kill -9 $pids 2>/dev/null || true
        fi
        ip netns del "$ns" && log_info "namespace removed: $ns"
    done < <(ip netns list 2>/dev/null | awk -v p="^${LAB_PREFIX}${rid}_" '$1 ~ p {print $1}')
    # Any stray lab veth that ended up in the root namespace.
    ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E "^${LAB_PREFIX}${rid}_" | while read -r l; do
        ip link del "$l" 2>/dev/null || true
    done
    netem_clear 2>/dev/null || true
    log_info "teardown complete for run id $rid"
}

# Global janitor: remove leftovers from ANY past lab run (qmx<hex>_).
# Refuses anything that does not match the exact lab naming scheme.
lab_clean_all() {
    local n=0 ns l
    while read -r ns; do
        [ -n "$ns" ] || continue
        local pids; pids="$(ip netns pids "$ns" 2>/dev/null || true)"
        [ -n "$pids" ] && { kill $pids 2>/dev/null || true; kill -9 $pids 2>/dev/null || true; }
        ip netns del "$ns" && { log_info "removed orphan namespace $ns"; n=$((n+1)); }
    done < <(ip netns list 2>/dev/null | awk -v p="^${LAB_PREFIX}[0-9a-f]+_" '$1 ~ p {print $1}')
    while read -r l; do
        [ -n "$l" ] || continue
        ip link del "$l" 2>/dev/null && { log_info "removed orphan interface $l"; n=$((n+1)); }
    done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E "^${LAB_PREFIX}[0-9a-f]+_" || true)
    log_info "cleanup done ($n objects removed)"
}
