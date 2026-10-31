#!/usr/bin/env python3
"""validate_report.py — validate a lab run report against the contract.

Usage: validate_report.py <report.json>

Full JSON-Schema validation when the `jsonschema` package is available;
otherwise a strict structural check (stdlib only) covering the same
required fields. Exit 0 = valid, 1 = invalid.
"""
import json
import sys

REQUIRED_TOP = ["schema", "meta", "safety", "tests"]
REQUIRED_META = ["run_id", "started_utc", "engine_mode", "scenario"]
REQUIRED_SAFETY = ["preflight", "root_firewall_policy"]
TEST_STATUSES = {"pass", "fail", "unknown", "skipped"}
ENGINE_MODES = {"real", "calibration", "external"}
TEST_IDS_EXPECTED_PREFIX = "T"


def structural_check(r):
    errs = []
    for k in REQUIRED_TOP:
        if k not in r:
            errs.append(f"missing top-level key: {k}")
    meta = r.get("meta", {})
    for k in REQUIRED_META:
        if k not in meta:
            errs.append(f"meta missing: {k}")
    if meta.get("engine_mode") not in ENGINE_MODES:
        errs.append(f"meta.engine_mode invalid: {meta.get('engine_mode')}")
    safety = r.get("safety", {})
    for k in REQUIRED_SAFETY:
        if k not in safety:
            errs.append(f"safety missing: {k}")
    tests = r.get("tests")
    if not isinstance(tests, list) or not tests:
        errs.append("tests must be a non-empty array")
    else:
        seen = set()
        for t in tests:
            if not isinstance(t, dict):
                errs.append("test entry is not an object")
                continue
            for k in ("id", "status", "summary"):
                if k not in t:
                    errs.append(f"test {t.get('id', '?')} missing: {k}")
            if t.get("status") not in TEST_STATUSES:
                errs.append(f"test {t.get('id', '?')} bad status: {t.get('status')}")
            seen.add(t.get("id"))
        expected = {f"T{i:02d}_{name}" for i, name in [
            (1, "startup"), (2, "latency"), (3, "jitter"), (4, "packet_loss"),
            (5, "throughput"), (6, "recovery"), (7, "cpu"), (8, "ram"),
            (9, "iface_counters"), (10, "transport_traffic"), (11, "payload"),
            (12, "amplification")]}
        missing = {e for e in expected if e not in seen}
        if missing and r.get("meta", {}).get("suite", "run") == "run":
            errs.append(f"run-mode report missing tests: {sorted(missing)}")
    counters = r.get("counters", {})
    if counters and "phases" in counters:
        for ph, p in counters["phases"].items():
            if "acct_deltas" not in p or "iface_deltas" not in p:
                errs.append(f"counters.phases.{ph} incomplete")
    return errs


def main():
    path = sys.argv[1]
    try:
        report = json.load(open(path))
    except Exception as e:
        print(f"INVALID: cannot parse report: {e}")
        sys.exit(1)

    errs = structural_check(report)

    try:
        import jsonschema  # optional
        schema = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else None
        if schema:
            jsonschema.validate(report, schema)
            print("jsonschema: OK")
    except ImportError:
        pass
    except Exception as e:
        errs.append(f"jsonschema validation failed: {e}")

    if errs:
        print("INVALID:")
        for e in errs:
            print(f"  - {e}")
        sys.exit(1)
    print("VALID: report satisfies the lab report contract")


if __name__ == "__main__":
    main()
