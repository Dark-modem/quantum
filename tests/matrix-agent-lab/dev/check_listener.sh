#!/usr/bin/env bash
# dev/check_listener.sh — what address does tincd actually bind? (debug aid)
set -uo pipefail
export LAB_ROOT=/opt/qmx-lab
cd /opt/qmx-lab
. lib/common.sh
. lib/safety.sh
. lib/netns.sh
. lib/engine.sh
. lib/traffic.sh

lab_load_conf
lab_new_runid
RUN_DIR=/opt/qmx-lab/results/dev-listener
mkdir -p "$RUN_DIR/engine" "$RUN_DIR/counters"
trap 'netns_teardown_run' EXIT

ip netns add "$(lab_name t)" 2>/dev/null || true
ip -n "$(lab_name t)" link add d0 type dummy
ip -n "$(lab_name t)" link set d0 up
ip -n "$(lab_name t)" addr add 10.55.0.1/24 dev d0

mkdir -p "$(engine_conf_dir kharej)/hosts"
cat > "$(engine_conf_dir kharej)/tinc.conf" <<EOF
Name = kharej
Device = /dev/net/tun
AddressFamily = ipv4
DirectOnly = yes
AutoConnect = yes
EOF
cat > "$(engine_conf_dir kharej)/hosts/kharej" <<EOF
Address = 10.55.0.1
Subnet = 172.16.99.2/32
Port = 2097
EOF
mkdir -p "$(engine_conf_dir kharej)"
cat > "$(engine_conf_dir kharej)/tinc-up" <<'EOF'
#!/bin/sh
/sbin/ip link set $INTERFACE up
/sbin/ip addr add 172.16.99.2/32 dev $INTERFACE
EOF
chmod +x "$(engine_conf_dir kharej)/tinc-up"
yes '' | tincd -c "$(engine_conf_dir kharej)" -n matrix -K2048 >/dev/null 2>&1

ip netns exec "$(lab_name t)" tincd -D -c "$(engine_conf_dir kharej)" -n matrix \
    --pidfile="$RUN_DIR/tpid" >>"$RUN_DIR/tincd.log" 2>&1 &
sleep 2
echo "--- ss -tlnp in ns ---"
ip netns exec "$(lab_name t)" ss -tlnp 2>/dev/null
echo "--- ss -ulnp in ns ---"
ip netns exec "$(lab_name t)" ss -ulnp 2>/dev/null

# add a client ns + veth and run the real DPI prober against the listener
ip netns add "$(lab_name c)" 2>/dev/null || true
ip link add "$(lab_name v1)" type veth peer name "$(lab_name v2)"
ip link set "$(lab_name v1)" netns "$(lab_name t)" name cin
ip link set "$(lab_name v2)" netns "$(lab_name c)" name cin
ip -n "$(lab_name t)" addr add 10.99.0.1/30 dev cin
ip -n "$(lab_name c)" addr add 10.99.0.2/30 dev cin
ip -n "$(lab_name t)" link set cin up
ip -n "$(lab_name c)" link set cin up
echo "--- prober from client ns ---"
ip netns exec "$(lab_name c)" python3 /opt/qmx-lab/tools/dpi_prober.py 10.99.0.1 2097 "$RUN_DIR/probes.json"
echo "--- tincd log ---"
tail -5 "$RUN_DIR/tincd.log"
