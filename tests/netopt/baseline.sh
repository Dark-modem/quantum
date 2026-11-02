#!/usr/bin/env bash
# netopt baseline harness — run on BOTH servers of the real Matrix pair.
# Captures detection, NIC facts, counters and direct+tunnel throughput per
# direction into a timestamped directory (tests/netopt/runs/<ts>-<host>/).
#
# Usage: baseline.sh <peer-host> <peer-tunnel-ip> [iperf_seconds]
#   <peer-host>      public/reachable address for the DIRECT (L1) runs
#   <peer-tunnel-ip> the peer's Matrix interface address (qmx*) for the
#                    TUNNEL (L2) runs — iperf3 through qmx must target it,
#                    otherwise "tunnel" runs silently ride the direct path.
# Requires: iperf3 on both ends (peer runs `iperf3 -s`).
# The tunnel interface name is auto-detected (qmx* / tun* / matrix*).
set -euo pipefail

PEER="${1:?usage: baseline.sh <peer-host> <peer-tunnel-ip> [iperf_seconds]}"
TUNIP="${2:?usage: baseline.sh <peer-host> <peer-tunnel-ip> [iperf_seconds]}"
SECS="${3:-30}"
STAMP="$(date +%Y%m%d-%H%M%S)"
HOSTTAG="$(hostname -s 2>/dev/null || echo host)"
OUT="runs/${STAMP}-${HOSTTAG}"
mkdir -p "$OUT"

echo "[netopt-baseline] output dir: $OUT  (direct=$PEER tunnel=$TUNIP)"

PANEL_BIN=/usr/local/bin/gre-panel
if [ ! -x "$PANEL_BIN" ]; then PANEL_BIN=gre-panel; fi

# L0: detection + link facts + counters
"$PANEL_BIN" netopt detect > "$OUT/detect.json" 2>"$OUT/detect.err" || echo "warn: netopt detect failed"
PRIMARY="$(python3 -c 'import json;d=json.load(open("'"$OUT"'/detect.json"));print(d.get("primary_iface",""))' 2>/dev/null || true)"
[ -n "$PRIMARY" ] && ethtool "$PRIMARY" > "$OUT/ethtool-primary.txt" 2>&1 || true
cp /proc/net/dev "$OUT/proc-net-dev.before"
TUN="$(ls /sys/class/net | grep -m1 -E '^(qmx|tun|matrix)' || true)"
printf 'primary_if=%s\ntunnel_if=%s\ndirect_peer=%s\ntunnel_peer=%s\n' \
  "$PRIMARY" "$TUN" "$PEER" "$TUNIP" > "$OUT/env.txt"

cpu_sample() { ( grep '^cpu ' /proc/stat; sleep 1; grep '^cpu ' /proc/stat ) > "$1"; }

# L1: DIRECT throughput, both directions, 3 runs
for i in 1 2 3; do
  iperf3 -c "$PEER" -t "$SECS" --json > "$OUT/direct-to-peer-$i.json" 2>&1 || true
  iperf3 -c "$PEER" -t "$SECS" --json -R > "$OUT/direct-from-peer-$i.json" 2>&1 || true
done

# L2/L3: TUNNEL throughput (target = tunnel address) + CPU samples
for i in 1 2 3; do
  cpu_sample "$OUT/cpu-during-to-peer-$i.txt" & CPUPID=$!
  iperf3 -c "$TUNIP" -t "$SECS" --json > "$OUT/tunnel-to-peer-$i.json" 2>&1 || true
  wait $CPUPID 2>/dev/null || true
  cpu_sample "$OUT/cpu-during-from-peer-$i.txt" & CPUPID=$!
  iperf3 -c "$TUNIP" -t "$SECS" --json -R > "$OUT/tunnel-from-peer-$i.json" 2>&1 || true
  wait $CPUPID 2>/dev/null || true
done

cp /proc/net/dev "$OUT/proc-net-dev.after"
nstat -az > "$OUT/nstat.after" 2>/dev/null || true

echo "[netopt-baseline] done. Aggregate with: python3 tests/netopt/compare.py <runA> <runB>"
