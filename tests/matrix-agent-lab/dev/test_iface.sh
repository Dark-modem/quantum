#!/usr/bin/env bash
# dev/test_iface.sh — reproduce iface_snapshot in-file (debug aid)
set -uo pipefail
export LAB_ROOT=/opt/qmx-lab
cd /opt/qmx-lab
. lib/common.sh
. lib/safety.sh
. lib/netns.sh
. lib/traffic.sh

lab_new_runid
RUN_DIR=/opt/qmx-lab/results/dev-iface
mkdir -p "$RUN_DIR/counters"
lab_load_conf

ip netns add "$(lab_name t)" 2>/dev/null || true
ip -n "$(lab_name t)" link add wan0 type dummy 2>/dev/null || true
ip -n "$(lab_name t)" link set wan0 up 2>/dev/null || true

echo "direct call: [$(iface_rx_bytes "$(lab_name t)" wan0)]"

# temporary override to point IFACE_LIST at the test ns
IFACE_LIST="$(lab_name t) wan0"
f="$RUN_DIR/counters/iface-dev.csv"
echo "ts,ns,iface,rx_bytes,tx_bytes" > "$f"
ts=$(date +%s)
echo "$IFACE_LIST" | tr '|' '\n' | while read -r ns iface; do
    [ -n "$ns" ] || continue
    printf '%s,%s,%s,%s,%s\n' "$ts" "$ns" "$iface" \
        "$(iface_rx_bytes "$ns" "$iface")" "$(iface_tx_bytes "$ns" "$iface")" >> "$f"
done
echo "snapshot result:"
cat "$f"

ip netns del "$(lab_name t)" 2>/dev/null || true
