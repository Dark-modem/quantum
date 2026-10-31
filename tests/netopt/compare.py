#!/usr/bin/env python3
"""netopt compare — join two baseline runs into a per-direction comparison.

Usage: compare.sh runA runB        (two runs/ directories from baseline.sh)
Prints a table: per-direction median Mbit/s, tunnel/direct ratios, error
counters and CPU deltas, plus the bottleneck verdicts from
docs/NETOPT-PERF.md section 3 (L1 vs L2 decision rules).
"""
import json
import statistics
import sys
from pathlib import Path


def load_run(d: Path):
    out = {"direct": {}, "tunnel": {}, "counters": {}, "cpu": {}}
    for f in d.glob("direct-*.json"):
        key = "to_peer" if "-to-peer-" in f.name else "from_peer"
        out["direct"].setdefault(key, []).append(_iperf_mbits(f))
    for f in d.glob("tunnel-*.json"):
        key = "to_peer" if "-to-peer-" in f.name else "from_peer"
        out["tunnel"].setdefault(key, []).append(_iperf_mbits(f))
    before = _proc_net_dev(d / "proc-net-dev.before")
    after = _proc_net_dev(d / "proc-net-dev.after")
    for iface in set(before) & set(after):
        out["counters"][iface] = {
            k: after[iface][k] - before[iface][k]
            for k in ("rx_bytes", "rx_errors", "rx_dropped", "tx_bytes", "tx_errors", "tx_dropped")
        }
    return out


def _iperf_mbits(f: Path):
    try:
        data = json.loads(f.read_text())
        end = data.get("end", {})
        sec = end.get("sum_received") or end.get("sum_sent") or {}
        return round(sec.get("bits_per_second", 0) / 1e6, 2)
    except Exception:
        return None


def _proc_net_dev(p: Path):
    out = {}
    if not p.exists():
        return out
    for line in p.read_text().splitlines():
        if ":" not in line or "|" in line:
            continue
        name, rest = line.split(":", 1)
        f = rest.split()
        if len(f) < 16:
            continue
        out[name.strip()] = {
            "rx_bytes": int(f[0]), "rx_errors": int(f[2]), "rx_dropped": int(f[3]),
            "tx_bytes": int(f[8]), "tx_errors": int(f[10]), "tx_dropped": int(f[11]),
        }
    return out


def median(vals):
    vals = [v for v in vals if v is not None]
    return statistics.median(vals) if vals else None


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    a, b = load_run(Path(sys.argv[1])), load_run(Path(sys.argv[2]))
    names = {"to_peer": "A->peer", "from_peer": "peer->A"}
    print(f"{'direction':10} {'metric':22} {'runA':>10} {'runB':>10}")
    for key in ("to_peer", "from_peer"):
        for path in ("direct", "tunnel"):
            ma, mb = median(a[path].get(key, [])), median(b[path].get(key, []))
            print(f"{names[key]:10} {path + ' Mbit/s (median)':22} {ma!s:>10} {mb!s:>10}")
        d1, t1 = median(a["direct"].get(key, [])), median(a["tunnel"].get(key, []))
        d2, t2 = median(b["direct"].get(key, [])), median(b["tunnel"].get(key, []))
        if d1 and t1:
            print(f"{names[key]:10} {'tunnel/direct ratio A':22} {t1 / d1:>10.2f}")
        if d2 and t2:
            print(f"{names[key]:10} {'tunnel/direct ratio B':22} {t2 / d2:>10.2f}")
    # verdict per docs/NETOPT-PERF.md §3
    for key in ("to_peer", "from_peer"):
        d2, t2 = median(b["direct"].get(key, [])), median(b["tunnel"].get(key, []))
        if d2 and t2 and abs(t2 - d2) / max(d2, 1) < 0.15:
            print(f"VERDICT {names[key]}: tunnel ~= direct -> PATH bottleneck, "
                  "not the tunnel; do not tune the tunnel for throughput here.")
        elif d2 and t2 and t2 < d2 * 0.7:
            print(f"VERDICT {names[key]}: tunnel << direct -> tunnel overhead "
                  "measurable; check CPU deltas (L3) before proposing changes.")
    for iface, c in b["counters"].items():
        if c["rx_errors"] or c["tx_errors"] or c["tx_dropped"]:
            print(f"WARN {iface}: errors/drops during run: {c}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
