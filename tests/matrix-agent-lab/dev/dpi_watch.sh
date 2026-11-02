#!/usr/bin/env bash
# dev/dpi_watch.sh — instrument the in-run prober window end-to-end (debug aid)
cd /opt/qmx-lab
./bin/labctl clean >/dev/null 2>&1
./bin/labctl dpi clean --keep > /tmp/dpi5.log 2>&1 &
RUNPID=$!

# wait for the capture phase (starts ~t+9s, lasts 15s), then watch wan0
sleep 20
NSI=$(ip netns list | awk '/_iran/{print $1}' | head -1)
echo "[watch] tcpdump on $NSI wan0, 40s, port 2097:"
ip netns exec "$NSI" timeout 40 tcpdump -i wan0 -nn 'tcp port 2097' 2>/dev/null | head -12
wait $RUNPID
RC=$?
echo "[watch] run finished rc=$RC"
R=$(grep -oE 'run-[0-9a-f]{8}' /tmp/dpi5.log | head -1)
echo "[watch] in-run prober results ($R):"
python3 - "$R" <<'PYEOF'
import json, sys
d = json.load(open(f"/opt/qmx-lab/results/{sys.argv[1]}/pcap/active_probes.json"))
for p in d["probes"]:
    print(" ", p["probe"], "->", p.get("connect"), p.get("behavior", ""))
PYEOF
echo "[watch] iran tincd.log tail:"
tail -6 "/opt/qmx-lab/results/$R/engine/iran/tincd.log"
