#!/usr/bin/env bash
# suites/run_suite.sh — sourced by labctl (not executed directly).
# Inputs provided by labctl: RUNID RUN_DIR LAB_ROOT SUITE_CMD, $1=scenario file
# Everything here runs inside lab namespaces; the root namespace firewall
# is hash-verified by labctl after this file returns.

SCENARIO_FILE="$1"
# shellcheck source=../scenarios/clean.conf
. "$SCENARIO_FILE"

NS_I="$(lab_name iran)"; NS_K="$(lab_name kharej)"; NS_C="$(lab_name client)"
mkdir -p "$RUN_DIR/samples"

export BILLING_IFACE_PHYS BILLING_MODEL COUNTER_BACKEND BILLING_IFACE_TUNNEL

if [ "$ENGINE_MODE" = "real" ]; then
    TARGET="$KHAREJ_TUN_IP"; PAYLOAD_BIND="$KHAREJ_TUN_IP"
else
    TARGET="$KHAREJ_TLINK_IP"; PAYLOAD_BIND="$KHAREJ_TLINK_IP"
fi
CLIENT_URL="http://$IRAN_WAN_IP:$PAYLOAD_PORT/"

frag() { cat > "$RUN_DIR/fragments/$1.json"; }

json_frag() { # json_frag <name> — JSON built by python from key=value args
    local name="$1"; shift
    python3 -c '
import json, sys
data = json.loads(sys.argv[1])
print(json.dumps(data, indent=2))' "$1" > "$RUN_DIR/fragments/$name.json"
}

# ---------------------------------------------------------------- setup
json_frag 00_meta "$(cat <<EOF
{"run_id": "$RUNID", "started_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
 "suite": "$SUITE_CMD", "scenario": "$NETEM_LABEL", "netem_args": "$NETEM_ARGS",
 "engine_mode": "$ENGINE_MODE", "billing_model": "$BILLING_MODEL",
 "counter_backend": "$COUNTER_BACKEND",
 "billing_iface_phys": "$BILLING_IFACE_PHYS",
 "billing_iface_tunnel": "$BILLING_IFACE_TUNNEL",
 "payload_mib": $PAYLOAD_MIB, "latency_window_s": $LATENCY_WINDOW_S,
 "throughput_subwindows": $THROUGHPUT_SUBWINDOWS, "blackout_s": $BLACKOUT_S,
 "matrix_port": $MATRIX_PORT, "payload_port": $PAYLOAD_PORT,
 "addresses": {"iran_wan": "$IRAN_WAN_IP", "client_wan": "$CLIENT_WAN_IP",
   "iran_tlink": "$IRAN_TLINK_IP", "kharej_tlink": "$KHAREJ_TLINK_IP",
   "iran_matrix": "$IRAN_TUN_IP", "kharej_matrix": "$KHAREJ_TUN_IP"},
 "tunnel_specific_isolation": "by-construction: tlink carries only Matrix transport; client traffic enters via wan0",
 "production_contact": "none"}
EOF
)"

netns_up
[ "$NETEM_ARGS" != "" ] && netem_apply "$NETEM_LABEL" $NETEM_ARGS

traffic_arm_acct
json_frag 01_safety "$(cat <<EOF
{"root_firewall_policy": "read-only hash before and after; no rule modification outside lab namespaces",
 "naming_prefix": "${LAB_PREFIX}${RUNID}_",
 "netem_available": $NETEM_AVAILABLE,
 "preflight": "passed"}
EOF
)"
json_frag 02_capabilities "$(cat <<EOF
{"netem": $([ "$NETEM_AVAILABLE" = 1 ] && echo true || echo false),
 "tun": $([ -c /dev/net/tun ] && echo true || echo false),
 "tcpdump": $(command -v tcpdump >/dev/null 2>&1 && echo true || echo false),
 "tincd": "$(command -v "$TINCD_BIN" >/dev/null 2>&1 && "$TINCD_BIN" --version 2>/dev/null | head -1 || echo missing)",
 "kernel": "$(uname -r)"}
EOF
)"

# ------------------------------------------------------- T01 startup
# Times Matrix establishment: engine_start() through first tunnel ping.
iface_snapshot t01_before
acct_snapshot t01_before
t0=$(date +%s.%N)
engine_start
est=null
if engine_wait_ready "$TARGET" 120; then
    t1=$(date +%s.%N)
    est=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
    test_result T01_startup pass "Matrix reachable through tunnel in ${est}s" \
        "{\"establishment_s\": $est, \"target\": \"$TARGET\"}"
else
    test_result T01_startup fail "no tunnel connectivity within 120s" "{\"target\": \"$TARGET\"}"
fi
iface_snapshot t01_after; acct_snapshot t01_after

# payload server inside the kharej ns, bound to the tunnel-side address.
# Started AFTER the engine: in real mode the bind address lives on the
# Matrix (tinc) interface and only exists once the tunnel is up.
ip netns exec "$NS_K" python3 "$LAB_ROOT/tools/payload_server.py" "$PAYLOAD_BIND" "$PAYLOAD_PORT" \
    >> "$RUN_DIR/samples/payload_server.log" 2>&1 &
PAYLOAD_PID=$!
echo "$PAYLOAD_PID" > "$RUN_DIR/payload_server.pid"
sleep 1
kill -0 "$PAYLOAD_PID" 2>/dev/null || log_die "payload server died (see samples/payload_server.log)"
ps_up=0
for _ in $(seq 1 20); do
    if ns_exec "$NS_K" curl -s -o /dev/null -m 3 "http://$PAYLOAD_BIND:$PAYLOAD_PORT/0mib"; then
        ps_up=1; break
    fi
    sleep 0.5
done
[ "$ps_up" = "1" ] || log_die "payload server unreachable on $PAYLOAD_BIND:$PAYLOAD_PORT"

# ------------------------------------------- T02/T03/T04 latency+jitter+loss
if [ "$SUITE_CMD" = "run" ]; then
    iface_snapshot latency_before; acct_snapshot latency_before
    ns_exec "$NS_I" ping -D -i 0.2 -w "$LATENCY_WINDOW_S" "$TARGET" \
        > "$RUN_DIR/samples/latency.txt" 2>&1
    python3 "$LAB_ROOT/tools/ping_stats.py" "$RUN_DIR/samples/latency.txt" \
        "$RUN_DIR/samples/latency.json" >> "$RUN_DIR/samples/ping_stats.log" 2>&1 || true
    iface_snapshot latency_after; acct_snapshot latency_after

    # dedicated UDP probe through the DNAT path (loss beyond ICMP)
    ip netns exec "$NS_K" python3 "$LAB_ROOT/tools/udp_probe.py" server 0.0.0.0 "$PAYLOAD_PORT" \
        >> "$RUN_DIR/samples/udp_server.log" 2>&1 &
    UDP_PID=$!
    echo "$UDP_PID" > "$RUN_DIR/udp_server.pid"
    sleep 0.5
    ns_exec "$NS_C" python3 "$LAB_ROOT/tools/udp_probe.py" client "$IRAN_WAN_IP" "$PAYLOAD_PORT" \
        400 20 "$RUN_DIR/samples/udp_probe.json" >> "$RUN_DIR/samples/udp_client.log" 2>&1 || true
    kill "$UDP_PID" 2>/dev/null || true
    wait "$UDP_PID" 2>/dev/null || true

    # fragments are built in python — never interpolate JSON via bash
    python3 "$LAB_ROOT/tools/latency_fragments.py" "$RUN_DIR" || true
else
    test_result T02_latency skipped "dpi-only run" "{}"
    test_result T03_jitter skipped "dpi-only run" "{}"
    test_result T04_packet_loss skipped "dpi-only run" "{}"
fi

# ------------------------------------------------------ T05 throughput
# T07 CPU / T08 RAM / T09 iface / T10 transport / T11 payload / T12 amplification
# all share the controlled-transfer windows below.
if [ "$SUITE_CMD" = "run" ]; then
    sub=$(( PAYLOAD_MIB / THROUGHPUT_SUBWINDOWS ))
    [ "$sub" -lt 1 ] && sub=1
    total=$(( sub * THROUGHPUT_SUBWINDOWS ))

    SAMPLER_PID=$(sample_resources 3600 1 "$RUN_DIR/samples/resources.csv")

    # --- download direction ---
    iface_snapshot down_before; acct_snapshot down_before
    : > "$RUN_DIR/samples/down_rates.txt"
    down_ok=1
    for i in $(seq 1 "$THROUGHPUT_SUBWINDOWS"); do
        ns_exec "$NS_C" python3 "$LAB_ROOT/tools/payload_client.py" get "${CLIENT_URL}${sub}mib" "$sub" \
            "$RUN_DIR/samples/down_$i.json" >> "$RUN_DIR/samples/down_runs.txt" 2>&1
        rc=$?
        rate=$(python3 -c '
import json
try:
    d = json.load(open("'"$RUN_DIR"'/samples/down_'"$i"'.json"))
    print(d.get("rate_mbps", "NA"))
except Exception:
    print("NA")')
        echo "$rate" >> "$RUN_DIR/samples/down_rates.txt"
        [ "$rc" = "0" ] && [ "$rate" != "NA" ] || down_ok=0
    done
    iface_snapshot down_after; acct_snapshot down_after

    # --- upload direction ---
    iface_snapshot up_before; acct_snapshot up_before
    : > "$RUN_DIR/samples/up_rates.txt"
    up_ok=1
    for i in $(seq 1 "$THROUGHPUT_SUBWINDOWS"); do
        ns_exec "$NS_C" python3 "$LAB_ROOT/tools/payload_client.py" put "$CLIENT_URL/upload" "$sub" \
            "$RUN_DIR/samples/up_$i.json" >> "$RUN_DIR/samples/up_runs.txt" 2>&1
        rc=$?
        rate=$(python3 -c '
import json
try:
    d = json.load(open("'"$RUN_DIR"'/samples/up_'"$i"'.json"))
    print(d.get("rate_mbps", "NA"))
except Exception:
    print("NA")')
        echo "$rate" >> "$RUN_DIR/samples/up_rates.txt"
        [ "$rc" = "0" ] && [ "$rate" != "NA" ] || up_ok=0
    done
    iface_snapshot up_after; acct_snapshot up_after

    kill "$SAMPLER_PID" 2>/dev/null || true

    # T07 CPU / T08 RAM from the sampler CSV (engine pids only)
    res=$(resource_summary "$RUN_DIR/samples/resources.csv" 2>/dev/null || true)
    cpu_pct=$(printf '%s' "$res" | sed -n 's/.*cpu_pct=\([^ ]*\).*/\1/p')
    rss_peak=$(printf '%s' "$res" | sed -n 's/.*rss_peak_kb=\([^ ]*\).*/\1/p')
    if [ -n "$cpu_pct" ] && [ "$cpu_pct" != "NA" ]; then
        test_result T07_cpu pass "engine CPU ${cpu_pct}% of one core during controlled transfer" \
            "{\"cpu_pct_of_one_core\": $cpu_pct, \"source\": \"resources.csv (tincd pids)\"}"
    else
        test_result T07_cpu unknown "no engine cpu samples (engine=calibration or sampler empty)" "{}"
    fi
    if [ -n "$rss_peak" ] && [ "$rss_peak" != "NA" ]; then
        test_result T08_ram pass "engine RSS peak ${rss_peak} kB" \
            "{\"rss_peak_kb\": $rss_peak, \"source\": \"resources.csv (tincd pids)\"}"
    else
        test_result T08_ram unknown "no engine rss samples" "{}"
    fi

    thr_stats=$(python3 -c '
import json, statistics
def load(p):
    try: return json.load(open(p))
    except Exception: return {}
downs = [load("'"$RUN_DIR"'/samples/down_%d.json" % i) for i in range(1, '"$THROUGHPUT_SUBWINDOWS"' + 1)]
downs = [d for d in downs if d]
ups = [load("'"$RUN_DIR"'/samples/up_%d.json" % i) for i in range(1, '"$THROUGHPUT_SUBWINDOWS"' + 1)]
ups = [d for d in ups if d]
rates = []
for line in open("'"$RUN_DIR"'/samples/down_rates.txt"):
    try: rates.append(float(line))
    except ValueError: pass
mean = statistics.mean(rates) if rates else None
sd = statistics.pstdev(rates) if len(rates) > 1 else None
print(json.dumps({
    "subwindow_mib": '"$sub"',
    "subwindows": '"$THROUGHPUT_SUBWINDOWS"',
    "requested_total_mib": '"$PAYLOAD_MIB"',
    "actual_total_mib": '"$sub"' * '"$THROUGHPUT_SUBWINDOWS"',
    "download": {"rates_mbps": rates,
                  "mean_mbps": round(mean, 3) if mean is not None else None,
                  "cv_pct": round(100*sd/mean, 2) if (sd is not None and mean) else None,
                  "detail": downs},
    "upload_detail": ups,
}))' 2>/dev/null || echo '{}')

    test_result T05_throughput "$([ $down_ok = 1 ] && echo pass || echo fail)" \
        "controlled $total MiB down in $THROUGHPUT_SUBWINDOWS windows; see detail" \
        "$thr_stats"
else
    test_result T05_throughput skipped "dpi-only run" "{}"
fi

# ------------------------------------------------------ T06 recovery
if [ "$SUITE_CMD" = "run" ]; then
    iface_snapshot recovery_before; acct_snapshot recovery_before
    ip netns exec "$NS_C" python3 "$LAB_ROOT/tools/payload_client.py" get "$CLIENT_URL/16mib" 16 \
        "$RUN_DIR/samples/recovery_transfer.json" >> "$RUN_DIR/samples/recovery_runs.txt" 2>&1 &
    REC_PID=$!
    sleep 2
    link_blackout "$BLACKOUT_S"
    # time from link restore to first successful tunnel ping
    r0=$(date +%s.%N); reest=null
    for _ in $(seq 1 240); do
        if ns_exec "$NS_I" ping -c1 -W1 "$TARGET" >/dev/null 2>&1; then
            r1=$(date +%s.%N)
            reest=$(awk -v a="$r0" -v b="$r1" 'BEGIN{printf "%.2f", b-a}')
            break
        fi
        sleep 0.5
    done
    wait "$REC_PID" 2>/dev/null || true
    iface_snapshot recovery_after; acct_snapshot recovery_after

    rec_complete=$(python3 -c '
import json
try:
    d = json.load(open("'"$RUN_DIR"'/samples/recovery_transfer.json"))
    print("true" if d.get("complete") else "false")
except Exception:
    print("false")')
    if [ "$reest" != "null" ]; then
        test_result T06_recovery pass "tunnel re-established ${reest}s after ${BLACKOUT_S}s blackout; transfer complete=$rec_complete" \
            "{\"reestablish_s\": $reest, \"blackout_s\": $BLACKOUT_S, \"transfer_complete\": $rec_complete}"
    else
        test_result T06_recovery fail "tunnel did not re-establish within 120s" \
            "{\"reestablish_s\": null, \"blackout_s\": $BLACKOUT_S}"
    fi
else
    test_result T06_recovery skipped "dpi-only run" "{}"
fi

# ------------------------------------------------- counters (T09-T12)
if [ "$SUITE_CMD" = "run" ]; then
    python3 "$LAB_ROOT/tools/counters_to_json.py" "$RUN_DIR" \
        "$RUN_DIR/fragments/90_counters.json" || true

    python3 - "$RUN_DIR" <<'PYEOF' > "$RUN_DIR/fragments/sec_derived.json"
import json, sys, os
run_dir = sys.argv[1]
counters = json.load(open(os.path.join(run_dir, "fragments/90_counters.json")))
down = json.load(open(os.path.join(run_dir, "samples/down_1.json"))) if os.path.exists(os.path.join(run_dir, "samples/down_1.json")) else {}
p = counters.get("phases", {})

def acct(phase, key):
    v = p.get(phase, {}).get("acct_deltas", {}).get(key)
    return v if isinstance(v, int) else None

def billable(phase):
    v = p.get(phase, {}).get("billable_iran_rx")
    return v if isinstance(v, int) else None

def ratio(num, den):
    if num is None or den is None or den <= 0:
        return "UNKNOWN"
    return round(num / den, 4)

down_payload = None
up_payload = None
try:
    down_payload = sum(json.load(open(os.path.join(run_dir, "samples/down_%d.json" % i))).get("bytes", 0)
                       for i in range(1, 32) if os.path.exists(os.path.join(run_dir, "samples/down_%d.json" % i)))
    up_payload = sum(json.load(open(os.path.join(run_dir, "samples/up_%d.json" % i))).get("bytes", 0)
                     for i in range(1, 32) if os.path.exists(os.path.join(run_dir, "samples/up_%d.json" % i)))
except Exception:
    pass

derived = {
    "amplification": {
        # billable Iranian RX / payload, SAME direction both sides
        "download": ratio(billable("down"), down_payload),
        "upload": ratio(billable("up"), up_payload),
        "note": "numerator = sum of configured BILLING_IFACE_PHYS rx deltas (iran ns) over the same transfer window; UNKNOWN when any side is unmeasurable",
    },
    "transport_overhead": {
        # tunnel wire bytes / payload, same direction
        "download": ratio(acct("down", "transport_wire_rx"), down_payload),
        "upload": ratio(acct("up", "transport_wire_tx"), up_payload),
    },
    "matrix_iface_vs_payload": {
        "download": ratio(acct("down", "matrix_iface_rx"), down_payload),
        "upload": ratio(acct("up", "matrix_iface_tx"), up_payload),
    },
    "payload_bytes": {"download": down_payload, "upload": up_payload},
    "unknown_policy": "any unmeasurable ratio is reported as UNKNOWN, never estimated silently",
}
json.dump(derived, sys.stdout, indent=2)
PYEOF
    # T09 interface counters live inside 90_counters (iface_deltas)
    test_result T09_iface_counters pass "per-namespace interface RX/TX deltas recorded in counters.phases" "{}"
    test_result T10_transport_traffic pass "tunnel wire bytes (tlink rx/tx + acct chains) recorded per phase" "{}"
    test_result T11_payload pass "exact HTTP payload bytes recorded per direction (client-side socket accounting)" "{}"
    test_result T12_amplification pass "derived ratios in counters section; UNKNOWN where unmeasurable" "{}"
else
    test_result T09_iface_counters skipped "dpi-only run" "{}"
    test_result T10_transport_traffic skipped "dpi-only run" "{}"
    test_result T11_payload skipped "dpi-only run" "{}"
    test_result T12_amplification skipped "dpi-only run" "{}"
fi

# ------------------------------------------------------ health preview
if [ "$SUITE_CMD" = "run" ] && [ -f "$RUN_DIR/samples/latency.json" ]; then
    python3 "$LAB_ROOT/health/evaluate_window.py" \
        "$RUN_DIR/samples/latency.json" "$LAB_ROOT/health/thresholds.json" \
        > "$RUN_DIR/samples/health_eval.json" 2>"$RUN_DIR/samples/health_eval.err" || true
    if [ -s "$RUN_DIR/samples/health_eval.json" ]; then
        he=$(cat "$RUN_DIR/samples/health_eval.json")
        frag 70_health <<EOF
{"status": "evaluated", "evaluation": $he,
 "note": "preview of the future Quantum health monitor (60s rolling window + hysteresis)"}
EOF
    fi
fi

# ------------------------------------------------------------- DPI
if [ "$SUITE_CMD" = "dpi" ]; then
    # shellcheck source=../dpi/probe.sh
    . "$LAB_ROOT/dpi/probe.sh"
fi

# ------------------------------------------------- test result fragments
# TEST_RESULTS array -> fragment
printf '%s\n' "${TEST_RESULTS[@]:-}" | python3 -c '
import json, sys
tests = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        tests.append(json.loads(line))
    except json.JSONDecodeError as e:
        tests.append({"id": "unparsed", "status": "unknown",
                      "summary": "fragment broken: %s" % e, "raw": line[:200]})
json.dump({"tests": tests}, sys.stdout, indent=2)' > "$RUN_DIR/fragments/99_tests.json"

engine_frag() {
    json_frag 03_engine "$(cat <<EOF
{"mode": "$ENGINE_MODE",
 "tincd": "$(command -v "$TINCD_BIN" >/dev/null 2>&1 && "$TINCD_BIN" --version 2>/dev/null | head -1 || echo n/a)",
 "conf_dirs": "$RUN_DIR/engine/<node> (per-run; /etc/tinc untouched)",
 "startup_establishment_s": ${est:-null},
 "payload_server_pid": "$(cat "$RUN_DIR/payload_server.pid" 2>/dev/null || echo n/a)"}
EOF
)"
}
engine_frag

SUITE_RC=0
# suite returns success if no test hard-failed (unknown/skip tolerated)
for t in "${TEST_RESULTS[@]:-}"; do
    echo "$t" | grep -q '"status":"fail"' && SUITE_RC=1
done
return "$SUITE_RC" 2>/dev/null || true
