#!/usr/bin/env python3
"""payload_client.py — controlled payload transfer with exact byte counts.

Usage:
  payload_client.py get  <url> <mib> <outfile.json>
  payload_client.py put  <url> <mib> <outfile.json>

Emits one JSON object: {direction, requested_bytes, bytes, elapsed_s,
rate_mbps, complete}. `bytes` is what actually crossed the socket in the
payload direction (size_download / size_upload equivalent) and is the
DENOMINATOR of the amplification ratio for that same direction.
stdlib only.
"""
import http.client
import json
import sys
import time
from urllib.parse import urlparse
from urllib.request import urlopen

CHUNK = b"\xa5" * (256 * 1024)


def do_get(url, mib):
    total = mib * 1024 * 1024
    t0 = time.monotonic()
    moved = 0
    with urlopen(url, timeout=600) as resp:
        expected = int(resp.headers.get("Content-Length", total))
        while moved < expected:
            block = resp.read(min(256 * 1024, expected - moved))
            if not block:
                break
            moved += len(block)
    return moved, time.monotonic() - t0


def do_put(url, mib):
    total = mib * 1024 * 1024
    p = urlparse(url)
    conn = http.client.HTTPConnection(p.hostname, p.port, timeout=600)
    t0 = time.monotonic()
    moved = 0
    conn.putrequest("PUT", p.path or "/upload")
    conn.putheader("Content-Length", str(total))
    conn.endheaders()
    try:
        while moved < total:
            n = min(len(CHUNK), total - moved)
            conn.send(CHUNK[:n])
            moved += n
        resp = conn.getresponse()
        resp.read()
        status = resp.status
    finally:
        conn.close()
    return moved, time.monotonic() - t0, status


def main():
    direction, url, mib = sys.argv[1], sys.argv[2], int(sys.argv[3])
    outfile = sys.argv[4]
    result = {"direction": "download" if direction == "get" else "upload",
              "requested_bytes": mib * 1024 * 1024}
    try:
        if direction == "get":
            moved, elapsed = do_get(url, mib)
        else:
            moved, elapsed, status = do_put(url, mib)
            result["http_status"] = status
        result.update({
            "bytes": moved,
            "elapsed_s": round(elapsed, 3),
            "rate_mbps": round(moved * 8 / elapsed / 1e6, 3) if elapsed > 0 else None,
            "complete": moved == mib * 1024 * 1024,
            "status": "ok",
        })
    except Exception as e:  # record failure honestly
        result["status"] = "error"
        result["error"] = str(e)[:300]
    with open(outfile, "w") as f:
        json.dump(result, f, indent=2)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
