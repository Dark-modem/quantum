#!/usr/bin/env python3
"""latency_fragments.py — build T02/T03/T04 report fragments from samples.

Usage: latency_fragments.py <run_dir>
Reads samples/latency.json (ping_stats) and samples/udp_probe.json, then
writes fragments/test_T02_latency.json, test_T03_jitter.json and
test_T04_packet_loss.json. Doing this in python (instead of interpolating
JSON through bash) guarantees the fragments are always well-formed.
"""
import json
import os
import sys


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        return {"_error": str(e)[:200]}


def main():
    run_dir = sys.argv[1]
    frag_dir = os.path.join(run_dir, "fragments")
    os.makedirs(frag_dir, exist_ok=True)
    lat = load(os.path.join(run_dir, "samples", "latency.json"))
    udp = load(os.path.join(run_dir, "samples", "udp_probe.json"))

    if lat.get("count", 0) and not lat.get("_error"):
        with open(os.path.join(frag_dir, "test_T02_latency.json"), "w") as f:
            json.dump({
                "id": "T02_latency",
                "status": "pass",
                "summary": f"p95={lat['p95_ms']}ms over {lat['count']} samples",
                "detail": {"stats": lat},
            }, f, indent=2)
        with open(os.path.join(frag_dir, "test_T03_jitter.json"), "w") as f:
            json.dump({
                "id": "T03_jitter",
                "status": "pass",
                "summary": f"mean deviation {lat['jitter_ms']}ms",
                "detail": {"jitter_ms": lat["jitter_ms"], "source": "T02 samples"},
            }, f, indent=2)
    else:
        with open(os.path.join(frag_dir, "test_T02_latency.json"), "w") as f:
            json.dump({"id": "T02_latency", "status": "fail",
                       "summary": "no latency samples", "detail": {"stats": lat}}, f, indent=2)
        with open(os.path.join(frag_dir, "test_T03_jitter.json"), "w") as f:
            json.dump({"id": "T03_jitter", "status": "unknown",
                       "summary": "no samples", "detail": {}}, f, indent=2)

    if udp.get("status") == "ok":
        with open(os.path.join(frag_dir, "test_T04_packet_loss.json"), "w") as f:
            json.dump({
                "id": "T04_packet_loss",
                "status": "pass",
                "summary": f"UDP probe loss {udp['loss_pct']}%",
                "detail": {"udp_probe": udp},
            }, f, indent=2)
    else:
        with open(os.path.join(frag_dir, "test_T04_packet_loss.json"), "w") as f:
            json.dump({"id": "T04_packet_loss", "status": "unknown",
                       "summary": "udp probe did not run", "detail": {"udp_probe": udp}}, f, indent=2)
    print("T02/T03/T04 fragments written")


if __name__ == "__main__":
    main()
