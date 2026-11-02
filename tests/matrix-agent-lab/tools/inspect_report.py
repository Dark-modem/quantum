#!/usr/bin/env python3
"""inspect_report.py — quick human-readable dump of a lab report.

Usage: inspect_report.py <report.json> [test-id ...]
Development aid (safe to keep; not required by the harness).
"""
import json
import sys


def main():
    report = json.load(open(sys.argv[1]))
    want = set(sys.argv[2:])

    m = report.get("meta", {})
    print(f"run={m.get('run_id')} scenario={m.get('scenario')} engine={m.get('engine_mode')}")
    print(f"billing={m.get('billing_model')} payload_mib={m.get('payload_mib')}")

    for t in report.get("tests", []):
        if want and t.get("id") not in want:
            continue
        print(f"{t.get('id','?'):24s} {t.get('status','?'):8s} {t.get('summary','')[:100]}")

    ph = report.get("counters", {}).get("phases", {})
    for name in ("down", "up", "recovery"):
        p = ph.get(name)
        if not p:
            continue
        print(f"--- phase {name} ---")
        print("  acct:", json.dumps(p.get("acct_deltas")))
        print("  billable_iran_rx:", p.get("billable_iran_rx"))
        ifaces = p.get("iface_deltas") or {}
        for k in sorted(ifaces):
            v = ifaces[k]
            print(f"  {k:20s} rx={v.get('rx')} tx={v.get('tx')}")

    if report.get("dpi", {}).get("status"):
        print("dpi:", report["dpi"].get("status"))
    if report.get("health", {}).get("status"):
        print("health:", report["health"].get("status"),
              "switches:", len(report["health"].get("evaluation", {}).get("state_switches", [])))


if __name__ == "__main__":
    main()
