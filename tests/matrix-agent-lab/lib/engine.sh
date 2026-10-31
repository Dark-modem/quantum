#!/usr/bin/env bash
# lib/engine.sh — Matrix engine lifecycle inside lab namespaces.
#
# "real" mode runs the actual Matrix core (tincd, exactly what matrix.sh
# installs) with a per-run private config directory — /etc/tinc on this
# machine is never read or written. "calibration" mode is a plain routed
# forward used ONLY to validate the accounting math (~1.0 amplification);
# it is explicitly NOT a tunnel engine.

TINCD_BIN="${TINCD_BIN:-tincd}"

engine_conf_dir() { printf '%s/engine/%s' "$RUN_DIR" "$1"; }   # $1 = node name

_write_host_file() {
    local dir="$1" name="$2" tunip="$3" addr="$4"
    cat > "$dir/hosts/$name" <<EOF
Address = $addr
Subnet = $tunip/32
Port = $MATRIX_PORT
Cipher = aes-128-cbc
Digest = md5
PTMU = 1514
EOF
}

_write_updown() {
    local dir="$1" myip="$2" peerip="$3"
    cat > "$dir/tinc-up" <<EOF
#!/bin/sh
/sbin/ip link set \$INTERFACE up
/sbin/ip addr add $myip/32 dev \$INTERFACE
/sbin/ip route add $peerip/32 dev \$INTERFACE
EOF
    cat > "$dir/tinc-down" <<EOF
#!/bin/sh
/sbin/ip route del $peerip/32 dev \$INTERFACE
/sbin/ip addr del $myip/32 dev \$INTERFACE
/sbin/ip link set \$INTERFACE down
EOF
    chmod +x "$dir/tinc-up" "$dir/tinc-down"
}

# Generate full tinc config for one node (config dir mirrors matrix.sh
# layout, but under $RUN_DIR — the host's /etc/tinc is never touched).
engine_prepare_node() {
    local node="$1" myip="$2" myaddr="$3" peername="$4" peerip="$5"
    local dir; dir="$(engine_conf_dir "$node")"
    mkdir -p "$dir/hosts"

    {
        echo "Name = $node"
        echo "Device = /dev/net/tun"
        echo "AddressFamily = ipv4"
        echo "DirectOnly = yes"
        echo "AutoConnect = yes"
        echo "PingInterval = 10"
        echo "ProcessPriority = high"
        echo "ConnectTo = $peername"
    } > "$dir/tinc.conf"

    _write_host_file "$dir" "$node" "$myip" "$myaddr"
    _write_updown "$dir" "$myip" "$peerip"

    # RSA key generation, same shape as matrix.sh (hosts/<node> gets the
    # public key appended by tincd -K4096; bits must be ATTACHED to -K).
    # pipefail is disabled locally: `yes` exits 141 on SIGPIPE when tincd
    # closes stdin — that is the success path, not a failure.
    set +o pipefail
    yes '' 2>/dev/null | "$TINCD_BIN" -c "$dir" -n matrix -K4096 >/dev/null 2>&1
    local krc=$?
    set -o pipefail
    if [ "$krc" -ne 0 ]; then
        log_die "tincd key generation failed for $node (rc=$krc)"
    fi
    grep -q 'BEGIN RSA PUBLIC KEY' "$dir/hosts/$node" || log_die "public key missing in $dir/hosts/$node"
}

engine_start_real() {
    local ns_i ns_k
    ns_i="$(lab_name iran)"; ns_k="$(lab_name kharej)"

    engine_prepare_node kharej "$KHAREJ_TUN_IP" "$KHAREJ_TLINK_IP" iran "$IRAN_TUN_IP"
    engine_prepare_node iran   "$IRAN_TUN_IP"   "$IRAN_TLINK_IP"  kharej "$KHAREJ_TUN_IP"

    # Exchange host files (both include the peer's public key after -K)
    cp "$(engine_conf_dir iran)/hosts/iran"       "$(engine_conf_dir kharej)/hosts/iran"
    cp "$(engine_conf_dir kharej)/hosts/kharej"   "$(engine_conf_dir iran)/hosts/kharej"

    local pidf lp
    # Kharej first (it serves Address=KHAREJ_TLINK_IP the iran side dials).
    # Direct backgrounding of the whole `ip netns exec ... unshare ...`
    # chain: ip exec()s unshare, unshare exec()s tincd, so $! IS tincd.
    pidf="$RUN_DIR/engine/kharej/tincd.pid"
    ip netns exec "$ns_k" unshare -m --propagation private \
        sh -c 'mount -t tmpfs -o mode=0755 tmpfs /run 2>/dev/null; exec "$@"' sh \
        "$TINCD_BIN" -D -c "$(engine_conf_dir kharej)" -n matrix --pidfile="$pidf" \
        >>"$RUN_DIR/engine/kharej/tincd.log" 2>&1 &
    lp=$!
    echo "$lp" > "$RUN_DIR/engine/kharej/launcher.pid"
    sleep 1
    kill -0 "$lp" 2>/dev/null || log_die "kharej tincd died at startup (see engine/kharej/tincd.log)"

    pidf="$RUN_DIR/engine/iran/tincd.pid"
    ip netns exec "$ns_i" unshare -m --propagation private \
        sh -c 'mount -t tmpfs -o mode=0755 tmpfs /run 2>/dev/null; exec "$@"' sh \
        "$TINCD_BIN" -D -c "$(engine_conf_dir iran)" -n matrix --pidfile="$pidf" \
        >>"$RUN_DIR/engine/iran/tincd.log" 2>&1 &
    lp=$!
    echo "$lp" > "$RUN_DIR/engine/iran/launcher.pid"
    sleep 1
    kill -0 "$lp" 2>/dev/null || log_die "iran tincd died at startup (see engine/iran/tincd.log)"

    # Replicate matrix.sh tunnel_helper on the lab iran node:
    # DNAT client traffic arriving on wan0 into the kharej node through
    # the Matrix mesh + MASQUERADE out the tunnel interface.
    # These rules live ONLY inside the lab namespace.
    ns_exec "$ns_i" iptables -t nat -A PREROUTING -i wan0 -p tcp --dport "$PAYLOAD_PORT" \
        -j DNAT --to-destination "$KHAREJ_TUN_IP:$PAYLOAD_PORT"
    ns_exec "$ns_i" iptables -t nat -A PREROUTING -i wan0 -p udp --dport "$PAYLOAD_PORT" \
        -j DNAT --to-destination "$KHAREJ_TUN_IP:$PAYLOAD_PORT"
    ns_exec "$ns_i" iptables -t nat -A POSTROUTING -o matrix -j MASQUERADE
}

# Plain routed forward: wan0:PAYLOAD_PORT -> kharej tlink IP (tcp+udp,
# mirroring matrix.sh tunnel_helper). Lab-ns firewall rules only; the
# root firewall is never touched.
engine_start_calibration() {
    local ns_i; ns_i="$(lab_name iran)"
    ns_exec "$ns_i" iptables -t nat -A PREROUTING -i wan0 -p tcp --dport "$PAYLOAD_PORT" \
        -j DNAT --to-destination "$KHAREJ_TLINK_IP:$PAYLOAD_PORT"
    ns_exec "$ns_i" iptables -t nat -A PREROUTING -i wan0 -p udp --dport "$PAYLOAD_PORT" \
        -j DNAT --to-destination "$KHAREJ_TLINK_IP:$PAYLOAD_PORT"
    ns_exec "$ns_i" iptables -t nat -A POSTROUTING -o tlink -j MASQUERADE
    log_info "calibration forward armed (lab namespace $ns_i only)"
}

engine_start() {
    case "$ENGINE_MODE" in
        real)        engine_start_real ;;
        calibration) engine_start_calibration ;;
        external)    log_info "ENGINE_MODE=external — engine must be started by the caller (LAB_ENGINE_CMD)" ;;
        *) log_die "unknown ENGINE_MODE '$ENGINE_MODE'" ;;
    esac
}

# Wait until the target is reachable (through the tunnel in real mode).
engine_wait_ready() {
    local target="$1" timeout="${2:-120}" ns_i t=0
    ns_i="$(lab_name iran)"
    while [ "$t" -lt "$timeout" ]; do
        if ns_exec "$ns_i" ping -c1 -W1 "$target" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1; t=$((t+1))
    done
    return 1
}

# List of engine PIDs for CPU/RAM accounting. Real mode: the launcher
# PIDs recorded at engine start (these ARE the tincd processes); any
# other process sharing the namespace (payload server, probes) must not
# pollute engine resource accounting. Fallback: all pids in lab ns.
engine_pids() {
    local f
    if [ -f "$RUN_DIR/engine/iran/launcher.pid" ] || [ -f "$RUN_DIR/engine/kharej/launcher.pid" ]; then
        for f in "$RUN_DIR/engine/iran/launcher.pid" "$RUN_DIR/engine/kharej/launcher.pid"; do
            [ -f "$f" ] && cat "$f"
        done
    else
        local ns=""
        for ns in "$(lab_name iran)" "$(lab_name kharej)"; do
            ip netns pids "$ns" 2>/dev/null || true
        done | sort -u
    fi
}
