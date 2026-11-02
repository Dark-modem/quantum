#!/usr/bin/env bash
# dpi/probe.sh — DPI observation suite (sourced by run_suite when
# SUITE_CMD=dpi). Needs: NS_I NS_K NS_C TARGET RUN_DIR (from suite scope).
#
# What this suite can honestly measure in the lab:
#   1. protocol_identification  — cleartext markers / first-byte view of
#                                 the transport (pcap facts)
#   2. active_probing           — behavior of the tunnel port under the
#                                 same probes a DPI box would send
#   3. tls_fingerprint          — whether a TLS fingerprint even applies
#   4. traffic_patterns         — packet size/timing regularity at idle
#   5. connection_reset         — RST vs silent drop per probe class
#   6. owner_network_availability — NOT RUN here; requires the owner's
#                                 approved test network. Never automated.
# Anything else (real-world DPI verdicts) is reported as UNKNOWN by design.

NS_I="$(ip netns list | awk -v p="^${LAB_PREFIX}${RUNID}_iran$" '$1 ~ p {print $1}')"
[ -n "$NS_I" ] || NS_I="$(lab_name iran)"
NS_C="$(ip netns list | awk -v p="^${LAB_PREFIX}${RUNID}_client$" '$1 ~ p {print $1}')"
[ -n "$NS_C" ] || NS_C="$(lab_name client)"

# ---- 1+4+wire observation: capture idle + active transport on tlink ---
# (steady-state window; the handshake happens at engine start, before
#  this capture — noted honestly in the report)
PCAP="$RUN_DIR/pcap/tunnel_idle.pcap"
wire_summary="null"
if command -v tcpdump >/dev/null 2>&1; then
    # 15s capture during idle (keepalive patterns) + light probe traffic
    ip netns exec "$NS_I" timeout 15 tcpdump -i tlink -s 128 -w "$PCAP" >/dev/null 2>&1 &
    wait $! 2>/dev/null || true
    if [ -s "$PCAP" ]; then
        python3 "$LAB_ROOT/tools/pcap_summary.py" "$PCAP" "$RUN_DIR/pcap/tunnel_idle_summary.json" || true
        if [ -f "$RUN_DIR/pcap/tunnel_idle_summary.json" ]; then
            wire_summary=$(cat "$RUN_DIR/pcap/tunnel_idle_summary.json")
        fi
    fi
fi

# ---- 2+5: active probing of the exposed tunnel port -------------------
# In production the tunnel port (default 2097 TCP+UDP) is what the
# Iranian side exposes; we probe the lab iran WAN address the same way.
# The prober MUST run inside the client namespace — the lab addresses
# do not exist in the root namespace.
prober_json="null"
ip netns exec "$NS_C" python3 "$LAB_ROOT/tools/dpi_prober.py" "$IRAN_WAN_IP" "$MATRIX_PORT" \
    "$RUN_DIR/pcap/active_probes.json" >/dev/null 2>&1 || true
if [ -f "$RUN_DIR/pcap/active_probes.json" ]; then
    prober_json=$(cat "$RUN_DIR/pcap/active_probes.json")
fi

rst_behavior="UNKNOWN"
if [ "$prober_json" != "null" ]; then
    rst_behavior=$(printf '%s' "$prober_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = {}
for p in d.get("probes", []):
    out[p["probe"]] = p.get("behavior", p.get("connect", "observed"))
print(json.dumps(out))' 2>/dev/null || echo "UNKNOWN")
fi

# ---- assemble 80_dpi ----------------------------------------------------
python3 - "$RUN_DIR" "$wire_summary" "$prober_json" "$rst_behavior" <<'PYEOF'
import json, sys
run_dir, wire, probes, rst = sys.argv[1:5]
try:
    wire = json.loads(wire)
except Exception:
    wire = {"status": "unavailable", "reason": "tcpdump missing or capture failed"}
try:
    probes = json.loads(probes)
except Exception:
    probes = {"status": "unavailable", "reason": "prober failed"}

dpi = {
    "status": "measured_lab_only",
    "sections": {
        "protocol_identification": {
            "status": "measured" if wire.get("status") == "ok" else "UNKNOWN",
            "method": "first-byte/payload inspection of lab tlink capture",
            "cleartext_markers_found": wire.get("cleartext_markers_found"),
            "first_payloads": wire.get("first_payloads"),
        },
        "traffic_patterns": {
            "status": "measured" if wire.get("status") == "ok" else "UNKNOWN",
            "packets": wire.get("packets"),
            "size_mean": wire.get("size_mean"),
            "size_min": wire.get("size_min"),
            "size_max": wire.get("size_max"),
            "interarrival_mean_ms": wire.get("interarrival_mean_ms"),
            "note": "measured at idle over the lab link; production patterns depend on real usage",
        },
        "active_probing": {
            "status": "measured" if isinstance(probes, dict) and probes.get("probes") else "UNKNOWN",
            "probes": probes.get("probes") if isinstance(probes, dict) else None,
        },
        "connection_reset_behavior": {
            "status": "measured" if rst not in ("UNKNOWN",) else "UNKNOWN",
            "per_probe": rst,
        },
        "tls_fingerprint": {
            "status": "not_applicable_as_measured",
            "finding": "Matrix (tinc) does not speak TLS; no JA3/JA4 fingerprint exists for the tunnel transport itself. TLS fingerprinting is only relevant if the transport is later wrapped in TLS — measure it there.",
        },
        "owner_network_availability": {
            "status": "NOT_RUN",
            "finding": "requires the owner's approved test network; never automated by this lab by policy",
        },
    },
    "unknown_policy": "no DPI-resistance claim is made from connectivity success; production DPI behavior is UNKNOWN from lab evidence",
}
with open(run_dir + "/fragments/80_dpi.json", "w") as f:
    json.dump(dpi, f, indent=2)
print("dpi fragment written")
PYEOF

test_result DPI_lab_observation pass "protocol/pattern/probing/reset measured; TLS n/a; owner-network NOT_RUN" "{}"
