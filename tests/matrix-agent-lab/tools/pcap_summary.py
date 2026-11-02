#!/usr/bin/env python3
"""pcap_summary.py — factual summary of a lab tcpdump capture.

Usage: pcap_summary.py <capture.pcap> <outfile.json>
Reports ONLY measurable facts: packet counts, byte histogram, protocol
and port usage, inter-arrival stats, and whether known cleartext markers
appear in the payload. No DPI-resistance verdicts. stdlib only.
"""
import json
import statistics
import struct
import sys

TINC_CLEARTEXT_MARKERS = [b"SPTPS", b"Mesha", b" 1.", b"\x00matrix"]


def main():
    pcap, outfile = sys.argv[1], sys.argv[2]
    with open(pcap, "rb") as f:
        data = f.read()
    if len(data) < 24:
        json.dump({"status": "empty"}, open(outfile, "w"))
        return
    magic = data[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        endian = "<"
    elif magic == b"\xa1\xb2\xc3\xd4":
        endian = ">"
    else:
        json.dump({"status": "not_a_classic_pcap"}, open(outfile, "w"))
        return
    linktype = struct.unpack(endian + "I", data[20:24])[0]
    linkhdr = 14 if linktype == 1 else 0  # Ethernet II

    off = 24
    n = 0
    total_bytes = 0
    sizes = []
    iats = []
    last_ts = None
    proto_count = {}
    port_count = {}
    first_payloads = []
    blob = bytearray()
    while off + 16 <= len(data):
        ts_sec, ts_usec, incl, _orig = struct.unpack(endian + "IIII", data[off:off + 16])
        pkt = data[off + 16: off + 16 + incl]
        off += 16 + incl
        n += 1
        total_bytes += incl
        sizes.append(incl)
        ts = ts_sec + ts_usec / 1e6
        if last_ts is not None:
            iats.append(ts - last_ts)
        last_ts = ts

        l3 = pkt[linkhdr:]
        if len(l3) >= 20 and (l3[0] >> 4) == 4:
            proto = l3[9]
            proto_name = {6: "tcp", 17: "udp"}.get(proto, "other")
            proto_count[proto_name] = proto_count.get(proto_name, 0) + 1
            ihl = (l3[0] & 0xF) * 4
            if proto in (6, 17) and len(l3) >= ihl + 4:
                sp, dp = struct.unpack(">HH", l3[ihl:ihl + 4])
                for p in (sp, dp):
                    port_count[p] = port_count.get(p, 0) + 1
                if len(first_payloads) < 8:
                    l4 = ihl + (20 if proto == 6 else 8)
                    payload = l3[l4:]
                    if payload:
                        first_payloads.append({
                            "n": n, "proto": proto_name, "sport": sp, "dport": dp,
                            "len": len(payload),
                            "hex_head": payload[:48].hex(),
                            "ascii": "".join(chr(c) if 32 <= c < 127 else "." for c in payload[:48]),
                        })
                        blob.extend(payload[:512])

    markers = {m.decode("latin1").strip(): (m in blob) for m in TINC_CLEARTEXT_MARKERS}
    result = {
        "status": "ok",
        "linktype": linktype,
        "packets": n,
        "total_bytes": total_bytes,
        "size_mean": round(statistics.mean(sizes), 1) if sizes else None,
        "size_min": min(sizes) if sizes else None,
        "size_max": max(sizes) if sizes else None,
        "interarrival_mean_ms": round(statistics.mean(iats) * 1000, 3) if iats else None,
        "interarrival_max_ms": round(max(iats) * 1000, 3) if iats else None,
        "protocols": proto_count,
        "ports": port_count,
        "cleartext_markers_found": {k: v for k, v in markers.items()},
        "first_payloads": first_payloads,
    }
    json.dump(result, open(outfile, "w"), indent=2)
    print(json.dumps({k: v for k, v in result.items() if k != "first_payloads"}))


if __name__ == "__main__":
    main()
