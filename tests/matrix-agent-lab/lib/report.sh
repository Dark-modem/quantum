#!/usr/bin/env bash
# lib/report.sh — assemble the run JSON report from suite fragments.
#
# The suite writes fragments into $RUN_DIR/fragments/:
#   sec_<name>.json   — report sections (safety, capabilities, ...)
#   test_<id>_<x>.json — one object or {"tests":[...]} per test phase
# Assembly is done in python3 (stdlib only) so the JSON is always
# well-formed; bash never concatenates JSON by hand.

report_assemble() {
    python3 - "$RUN_DIR" "$LAB_ROOT" "$RUNID" <<'PYEOF'
import json, os, sys, hashlib

run_dir, lab_root, runid = sys.argv[1], sys.argv[2], sys.argv[3]
frag_dir = os.path.join(run_dir, "fragments")

SECTION_ORDER = ["00_meta", "01_safety", "02_capabilities", "03_engine",
                 "70_health", "80_dpi", "90_counters"]
SEC_PREFIXES = ("00_", "01_", "02_", "03_", "70_", "80_", "90_")

def load_frag(path, default):
    if not os.path.exists(path):
        return default
    with open(path) as f:
        try:
            return json.load(f)
        except json.JSONDecodeError as e:
            return {"_error": f"fragment unparseable: {path}: {e}"}

def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def frag(name, default):
    return load_frag(os.path.join(frag_dir, name + ".json"), default)

tests = []
sections = {}
if os.path.isdir(frag_dir):
    for fn in sorted(os.listdir(frag_dir)):
        if not fn.endswith(".json"):
            continue
        base = fn[:-5]
        if base.startswith(SEC_PREFIXES) or base.startswith("sec_"):
            continue
        obj = load_frag(os.path.join(frag_dir, fn), {})
        if isinstance(obj, list):
            tests.extend(obj)
        elif isinstance(obj, dict) and "tests" in obj:
            tests.extend(obj["tests"])
        else:
            tests.append(obj)

for key in SECTION_ORDER:
    sections[key] = frag(key, None)
# drop absent sections
sections = {k: v for k, v in sections.items() if v is not None}

report = {
    "schema": "matrix-agent-lab/report@1",
    "meta": frag("00_meta", {}),
    "safety": frag("01_safety", {}),
    "capabilities": frag("02_capabilities", {}),
    "engine": frag("03_engine", {}),
    "health": frag("70_health", {"status": "not_run"}),
    "dpi": frag("80_dpi", {"status": "not_run"}),
    "tests": tests,
    "counters": frag("90_counters", {}),
}

out = os.path.join(run_dir, "report.json")
with open(out, "w") as f:
    json.dump(report, f, indent=2, sort_keys=False)
print(out)
print(sha256_file(out))
PYEOF
}

report_validate() {
    python3 "$LAB_ROOT/tools/validate_report.py" "$RUN_DIR/report.json"
}
