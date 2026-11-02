#!/usr/bin/env python3
"""ping_stats.py — parse `ping -D` output into latency/jitter/loss stats.

Usage: ping_stats.py <ping_output.txt> <outfile.json>
Jitter = RFC 3550-style mean absolute consecutive RTT difference.
"""
import json
import re
import sys

TIME_RE = re.compile(r"time=([0-9.]+) ms")
SEQ_RE = re.compile(r"icmp_seq=(\d+)")
TS_RE = re.compile(r"^\[([0-9.]+)\]")


def main():
    src, out = sys.argv[1], sys.argv[2]
    samples = []
    series = []
    seqs = set()
    with open(src, errors="replace") as f:
        for line in f:
            if "time=" not in line:
                continue
            m = TIME_RE.search(line)
            s = SEQ_RE.search(line)
            t = TS_RE.search(line)
            if m:
                samples.append(float(m.group(1)))
                if t:
                    series.append([float(t.group(1)), float(m.group(1))])
            if s:
                seqs.add(int(s.group(1)))
    if not samples:
        json.dump({"status": "no_samples", "count": 0}, open(out, "w"), indent=2)
        print(json.dumps({"status": "no_samples"}))
        return
    xs = sorted(samples)
    n = len(xs)
    # Jitter uses ARRIVAL order (RFC 3550): consecutive RTT difference.
    diffs = [abs(samples[i] - samples[i - 1]) for i in range(1, n)]

    def pct(p):
        k = max(0, min(n - 1, int(round(p / 100.0 * (n - 1)))))
        return round(xs[k], 3)

    stats = {
        "status": "ok",
        "count": n,
        "min_ms": round(xs[0], 3),
        "mean_ms": round(sum(xs) / n, 3),
        "p95_ms": pct(95),
        "max_ms": round(xs[-1], 3),
        "jitter_ms": round(sum(diffs) / len(diffs), 3) if diffs else 0.0,
        "samples_ms": [round(x, 3) for x in xs],
    }
    # echo request count comes from the ping summary if present
    with open(src, errors="replace") as f:
        text = f.read()
    m = re.search(r"(\d+) packets transmitted", text)
    if m:
        tx = int(m.group(1))
        stats["transmitted"] = tx
        stats["loss_pct"] = round(100.0 * (tx - n) / tx, 3)
    else:
        stats["transmitted"] = len(seqs) or n
        stats["loss_pct"] = None
    stats["series"] = series  # [[unix_ts, rtt_ms], ...] for the health evaluator
    json.dump(stats, open(out, "w"), indent=2)
    slim = {k: v for k, v in stats.items() if k != "samples_ms"}
    print(json.dumps(slim))


if __name__ == "__main__":
    main()
