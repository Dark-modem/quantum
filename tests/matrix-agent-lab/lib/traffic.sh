#!/usr/bin/env bash
# lib/traffic.sh — traffic accounting and resource sampling.
#
# Two counter backends, both LAB-ONLY:
#   procfs   : byte deltas of /sys/class/net/<iface>/statistics inside
#              each lab namespace. Always available.
#   iptables : per-direction mangle accounting chains created INSIDE the
#              iran lab namespace only. The root firewall is untouched;
#              teardown removes exactly the chains this module created.
#
# Direction map (iran namespace) — each packet is counted exactly once:
#   client_payload_rx : PREROUTING -i wan0   (client -> iran, upload)
#   client_payload_tx : FORWARD    -o wan0   (iran -> client, download)
#   transport_wire_rx : PREROUTING -i tlink  (encapsulated, from kharej)
#   transport_wire_tx : POSTROUTING -o tlink (encapsulated, to kharej)
#   matrix_iface_rx   : FORWARD    -i matrix (decapsulated through Matrix)
#   matrix_iface_tx   : FORWARD    -o matrix (entering the Matrix tunnel)

ACCT_CHAIN_PRE="QMX${ACCT_TAG:-}PRE"
ACCT_CHAIN_FWD="QMX${ACCT_TAG:-}FWD"
ACCT_CHAIN_POST="QMX${ACCT_TAG:-}POST"

# --- procfs -------------------------------------------------------------

iface_rx_bytes() { ns_exec "$1" cat "/sys/class/net/$2/statistics/rx_bytes" 2>/dev/null || echo ""; }
iface_tx_bytes() { ns_exec "$1" cat "/sys/class/net/$2/statistics/tx_bytes" 2>/dev/null || echo ""; }

# Snapshot every tracked interface into RUN_DIR/counters/iface-<tag>.csv
# (counters_to_json.py reads the same naming convention)
IFACE_LIST="iran wan0|iran tlink|iran matrix|kharej tlink|kharej matrix|client wan0"

iface_snapshot() {
    local tag="$1" node iface ns
    mkdir -p "$RUN_DIR/counters"
    local f="$RUN_DIR/counters/iface-$tag.csv"
    echo "ts,ns,iface,rx_bytes,tx_bytes" > "$f"
    local ts; ts="$(date +%s)"
    # IFACE_LIST holds short node labels; resolve to the namespaced name.
    echo "$IFACE_LIST" | tr '|' '\n' | while read -r node iface; do
        [ -n "$node" ] || continue
        ns="$(lab_name "$node")"
        printf '%s,%s,%s,%s,%s\n' "$ts" "$node" "$iface" \
            "$(iface_rx_bytes "$ns" "$iface")" "$(iface_tx_bytes "$ns" "$iface")" >> "$f"
    done
    echo "$f"
}

# Delta between two snapshots: prints "ns iface rx_delta tx_delta"
iface_delta() {
    local b="$1" a="$2"
    awk -F, 'FNR==NR && FNR>1 { r[$2" "$3]=$4; t[$2" "$3]=$5; next }
             FNR>1 { k=$2" "$3;
                     dr=$4-r[k]; dt=$5-t[k];
                     if (r[k]=="" || $4=="") { print $2, $3, "NA", "NA" }
                     else { print $2, $3, dr, dt } }' \
        "$RUN_DIR/counters/iface-$b.csv" "$RUN_DIR/counters/iface-$a.csv"
}

# --- iptables accounting (inside the iran lab namespace ONLY) -----------

traffic_arm_acct() {
    local ns_i; ns_i="$(lab_name iran)"
    ACCT_CHAIN_PRE="QMX${RUNID}PRE"; ACCT_CHAIN_FWD="QMX${RUNID}FWD"; ACCT_CHAIN_POST="QMX${RUNID}POST"
    local chains=("$ACCT_CHAIN_PRE" "$ACCT_CHAIN_FWD" "$ACCT_CHAIN_POST") c

    for c in "${chains[@]}"; do
        ns_exec "$ns_i" iptables -t mangle -N "$c" 2>/dev/null || true
        ns_exec "$ns_i" iptables -t mangle -F "$c"
    done

    # Provider-side exclusions (configurable; empty by default — we do
    # not assume the provider excludes anything).
    if [ -n "${BILLING_EXCLUDES:-}" ]; then
        while IFS= read -r excl; do
            [ -n "$excl" ] || continue
            ns_exec "$ns_i" iptables -t mangle -A "$ACCT_CHAIN_PRE" $excl -j RETURN
        done <<< "$BILLING_EXCLUDES"
    fi

    # Each rule carries a unique comment; traffic_acct_bytes locates its
    # counter by comment (column positions differ across iptables builds).
    ns_exec "$ns_i" iptables -t mangle -A "$ACCT_CHAIN_PRE"  -i wan0 \
        -m comment --comment "qmxacct client_payload_rx" -j ACCEPT
    ns_exec "$ns_i" iptables -t mangle -A "$ACCT_CHAIN_PRE"  -i tlink \
        -m comment --comment "qmxacct transport_wire_rx" -j ACCEPT
    ns_exec "$ns_i" iptables -t mangle -A "$ACCT_CHAIN_FWD"  -i matrix \
        -m comment --comment "qmxacct matrix_iface_rx" -j ACCEPT
    ns_exec "$ns_i" iptables -t mangle -A "$ACCT_CHAIN_FWD"  -o matrix \
        -m comment --comment "qmxacct matrix_iface_tx" -j ACCEPT
    ns_exec "$ns_i" iptables -t mangle -A "$ACCT_CHAIN_FWD"  -o wan0 \
        -m comment --comment "qmxacct client_payload_tx" -j ACCEPT
    ns_exec "$ns_i" iptables -t mangle -A "$ACCT_CHAIN_POST" -o tlink \
        -m comment --comment "qmxacct transport_wire_tx" -j ACCEPT

    # Jumps at the TOP of the built-in chains — inside the lab namespace.
    ns_exec "$ns_i" iptables -t mangle -C PREROUTING  -j "$ACCT_CHAIN_PRE"  2>/dev/null || \
        ns_exec "$ns_i" iptables -t mangle -I PREROUTING  1 -j "$ACCT_CHAIN_PRE"
    ns_exec "$ns_i" iptables -t mangle -C FORWARD     -j "$ACCT_CHAIN_FWD"  2>/dev/null || \
        ns_exec "$ns_i" iptables -t mangle -I FORWARD     1 -j "$ACCT_CHAIN_FWD"
    ns_exec "$ns_i" iptables -t mangle -C POSTROUTING -j "$ACCT_CHAIN_POST" 2>/dev/null || \
        ns_exec "$ns_i" iptables -t mangle -I POSTROUTING 1 -j "$ACCT_CHAIN_POST"

    log_info "ns-local mangle accounting armed in $ns_i (chains ${ACCT_CHAIN_PRE}/${ACCT_CHAIN_FWD}/${ACCT_CHAIN_POST})"
}

# Read one rule's byte counter by its qmxacct comment.
# traffic_acct_bytes <dir-key> ; dir-key in: client_payload_rx client_payload_tx
#   transport_wire_rx transport_wire_tx matrix_iface_rx matrix_iface_tx
traffic_acct_bytes() {
    local key="$1" ns_i chain
    ns_i="$(lab_name iran)"
    case "$key" in
        client_payload_rx) chain="$ACCT_CHAIN_PRE" ;;
        transport_wire_rx) chain="$ACCT_CHAIN_PRE" ;;
        matrix_iface_rx)   chain="$ACCT_CHAIN_FWD" ;;
        matrix_iface_tx)   chain="$ACCT_CHAIN_FWD" ;;
        client_payload_tx) chain="$ACCT_CHAIN_FWD" ;;
        transport_wire_tx) chain="$ACCT_CHAIN_POST" ;;
        *) echo ""; return 1 ;;
    esac
    ns_exec "$ns_i" iptables -t mangle -nvx -L "$chain" 2>/dev/null | \
        awk -v m="qmxacct $key" '$0 ~ m {print $2; exit}'
}

traffic_disarm_acct() {
    local ns_i; ns_i="$(lab_name iran)"
    # Surgical removal: delete the jump rules we inserted, flush ONLY our
    # own named chains, delete them. Built-in chains keep every other rule.
    ns_exec "$ns_i" iptables -t mangle -D PREROUTING  -j "$ACCT_CHAIN_PRE"  2>/dev/null || true
    ns_exec "$ns_i" iptables -t mangle -D FORWARD     -j "$ACCT_CHAIN_FWD"  2>/dev/null || true
    ns_exec "$ns_i" iptables -t mangle -D POSTROUTING -j "$ACCT_CHAIN_POST" 2>/dev/null || true
    ns_exec "$ns_i" iptables -t mangle -F "$ACCT_CHAIN_PRE"  2>/dev/null || true
    ns_exec "$ns_i" iptables -t mangle -F "$ACCT_CHAIN_FWD"  2>/dev/null || true
    ns_exec "$ns_i" iptables -t mangle -F "$ACCT_CHAIN_POST" 2>/dev/null || true
    ns_exec "$ns_i" iptables -t mangle -X "$ACCT_CHAIN_PRE"  2>/dev/null || true
    ns_exec "$ns_i" iptables -t mangle -X "$ACCT_CHAIN_FWD"  2>/dev/null || true
    ns_exec "$ns_i" iptables -t mangle -X "$ACCT_CHAIN_POST" 2>/dev/null || true
    log_info "ns-local mangle accounting removed from $ns_i"
}

# --- CPU / RAM sampler ----------------------------------------------------
# Writes CSV: ts,pid,cpu_ticks,rss_kb  for each live pid, every interval.
# The background subshell MUST NOT inherit stdout of a possible command
# substitution, or the caller would block until the sampler ends.
sample_resources() {
    local secs="$1" interval="$2" out="$3"
    ( local end=$((SECONDS + secs))
      echo "ts,pid,cpu_ticks,rss_kb" > "$out"
      local pid ticks rss
      while [ "$SECONDS" -lt "$end" ]; do
          for pid in $(engine_pids); do
              ticks=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null) || ticks=""
              rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null) || rss=""
              printf '%s,%s,%s,%s\n' "$(date +%s)" "$pid" "${ticks:-NA}" "${rss:-NA}" >> "$out"
          done
          sleep "$interval"
      done ) >/dev/null 2>&1 &
    echo $!
}

# Summarize a resource CSV: cpu% of one core, rss peak KB.
resource_summary() {
    local file="$1" clk
    clk="$(getconf CLK_TCK 2>/dev/null || echo 100)"
    awk -F, -v clk="$clk" '
        NR == 1 { next }   # header row ("ts") would poison numeric tsmin
        $4 != "" && $4 != "NA" && $4+0 > peak { peak = $4+0 }
        { key=$2; first[key] == "" && first[key]=$3; last[key]=$3;
          if (tsmin=="" || $1+0 < tsmin+0) tsmin=$1;
          if (tsmax=="" || $1+0 > tsmax+0) tsmax=$1 }
        END {
            dt=0
            for (k in first) dt += last[k]-first[k]
            wall = tsmax-tsmin; if (wall <= 0) wall = 1
            cpupct = dt / clk / wall * 100
            if (peak == 0 && dt == 0) { print "cpu_pct=NA rss_peak_kb=NA" }
            else printf "cpu_pct=%.2f rss_peak_kb=%d\n", cpupct, peak
        }' "$file"
}

# --- accounting snapshot / delta (per-direction byte counters) ----------

ACCT_KEYS="client_payload_rx client_payload_tx transport_wire_rx transport_wire_tx matrix_iface_rx matrix_iface_tx"

acct_available() {
    [ "${COUNTER_BACKEND}" = "procfs" ] && return 1
    local ns_i; ns_i="$(lab_name iran)"
    ns_exec "$ns_i" iptables -t mangle -nvx -L "$ACCT_CHAIN_PRE" >/dev/null 2>&1
}

acct_snapshot() {
    local tag="$1" k
    mkdir -p "$RUN_DIR/counters"
    local f="$RUN_DIR/counters/acct-$tag.csv"
    echo "key,bytes" > "$f"
    if acct_available; then
        for k in $ACCT_KEYS; do
            printf '%s,%s\n' "$k" "$(traffic_acct_bytes "$k")" >> "$f"
        done
    else
        echo "unavailable,1" >> "$f"
    fi
    echo "$f"
}

acct_delta() {
    local b="$1" a="$2"
    awk -F, 'FNR==NR && FNR>1 { v[$1]=$2; next }
             FNR>1 && $1 != "unavailable" { d=$2-v[$1]; printf "%s %s\n", $1, (v[$1]==""? "NA" : d) }' \
        "$RUN_DIR/counters/acct-$b.csv" "$RUN_DIR/counters/acct-$a.csv"
}

# --- pcap (optional, for DPI observation) ---------------------------------
PCAP_PID=""

start_pcap() {
    local ns="$1" iface="$2" file="$3"
    command -v tcpdump >/dev/null 2>&1 || { log_warn "tcpdump missing — wire observation unavailable"; return 1; }
    ns_exec "$ns" tcpdump -i "$iface" -s 96 -w "$file" >/dev/null 2>&1 &
    PCAP_PID=$!
    return 0
}

stop_pcap() {
    [ -n "$PCAP_PID" ] || return 0
    kill "$PCAP_PID" 2>/dev/null || true
    wait "$PCAP_PID" 2>/dev/null || true
    PCAP_PID=""
}
