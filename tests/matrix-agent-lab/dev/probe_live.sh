#!/usr/bin/env bash
# dev/probe_live.sh — manual probes against a kept lab topology (debug aid)
NSI=$(ip netns list | awk '/_iran/{print $1}' | head -1)
NSC=$(ip netns list | awk '/_client/{print $1}' | head -1)
echo "iran=[$NSI] client=[$NSC]"
echo "--- tincd listener in iran ns ---"
ip netns exec "$NSI" ss -tlnp 2>/dev/null
echo "--- manual tcp probe from client ns ---"
ip netns exec "$NSC" timeout 3 bash -c 'exec 3<>/dev/tcp/10.100.0.1/2097 && echo CONNECTED' 2>&1
echo "--- manual tcp probe to tlink addr (10.200.0.1) from iran ns ---"
ip netns exec "$NSI" timeout 3 bash -c 'exec 3<>/dev/tcp/10.200.0.1/2097 && echo CONNECTED-LOCAL' 2>&1
echo "--- python prober from client ---"
ip netns exec "$NSC" python3 /opt/qmx-lab/tools/dpi_prober.py 10.100.0.1 2097 /tmp/liveprobes.json | head -3
