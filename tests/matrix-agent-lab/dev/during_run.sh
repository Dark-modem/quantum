#!/usr/bin/env bash
# dev/during_run.sh — instrument the prober failure window (debug aid)
cd /opt/qmx-lab
./bin/labctl clean >/dev/null 2>&1
./bin/labctl dpi clean --keep > /tmp/dpi4.log 2>&1 &
RUNPID=$!
sleep 14
NSI=$(ip netns list | awk '/_iran/{print $1}' | head -1)
NSC=$(ip netns list | awk '/_client/{print $1}' | head -1)
echo "ns: [$NSI] [$NSC]"
echo "--- listener ---"
ip netns exec "$NSI" ss -tln | grep 2097 || echo "NO LISTENER"
echo "--- parallel probe NOW (during run window) ---"
ip netns exec "$NSC" timeout 3 bash -c 'exec 3<>/dev/tcp/10.100.0.1/2097 && echo CONNECTED-DURING-RUN' 2>&1
echo "--- prober while tcpdump watches wan0 in iran ns ---"
ip netns exec "$NSC" timeout 6 python3 /opt/qmx-lab/tools/dpi_prober.py 10.100.0.1 2097 /tmp/during.json >/dev/null 2>&1 &
PROBE=$!
ip netns exec "$NSI" timeout 5 tcpdump -i wan0 -nn 2>/dev/null | head -10
wait $PROBE 2>/dev/null
echo "--- during.json ---"
head -c 400 /tmp/during.json 2>/dev/null; echo
kill $RUNPID 2>/dev/null
wait $RUNPID 2>/dev/null
echo RUN_DONE
