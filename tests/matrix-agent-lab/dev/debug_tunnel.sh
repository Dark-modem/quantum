#!/usr/bin/env bash
# dev/debug_tunnel.sh — live inspection of the current lab run (debug aid)
NSI=$(ip netns list | awk '/_iran/{print $1}' | head -1)
NSK=$(ip netns list | awk '/_kharej/{print $1}' | head -1)
NSC=$(ip netns list | awk '/_client/{print $1}' | head -1)
echo "ns: [$NSI] [$NSK] [$NSC]"
[ -z "$NSI" ] && { echo "no lab namespaces alive"; exit 0; }

echo "--- tinc processes ---"
ip netns pids "$NSI" | head -5

echo "--- tinc meta connection (iran ss) ---"
ip netns exec "$NSI" ss -tnp 2>/dev/null | head -8

echo "--- iran -> kharej through tunnel (172.16.99.2) ---"
ip netns exec "$NSI" ping -c2 -W2 172.16.99.2 2>&1 | tail -2

echo "--- iran -> kharej plain tlink (10.200.0.2) ---"
ip netns exec "$NSI" ping -c2 -W2 10.200.0.2 2>&1 | tail -2

echo "--- DNAT rules in iran ns ---"
ip netns exec "$NSI" iptables -t nat -S PREROUTING 2>/dev/null | head -5
ip netns exec "$NSI" iptables -t nat -S POSTROUTING 2>/dev/null | head -5

echo "--- client curl 0mib via DNAT (3s timeout) ---"
ip netns exec "$NSC" curl -s -o /dev/null -m 3 -w "code=%{http_code} bytes=%{size_download}\n" "http://10.100.0.1:8080/0mib"

echo "--- kharej local curl to payload server ---"
ip netns exec "$NSK" curl -s -o /dev/null -m 3 -w "code=%{http_code} bytes=%{size_download}\n" "http://172.16.99.2:8080/0mib"

echo "--- routes in iran ns ---"
ip netns exec "$NSI" ip route | head -6
echo "--- tincd logs tail (iran) ---"
tail -5 /opt/qmx-lab/results/*/engine/iran/tincd.log 2>/dev/null | tail -8
