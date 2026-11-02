#!/usr/bin/env python3
"""counters_to_json.py — turn lab counter snapshots into report JSON.

Usage: counters_to_json.py <run_dir> <outfile.json>
Snapshot pairs (before,after) expected in <run_dir>/counters/:
  iface-<tag>.csv   (ts,ns,iface,rx_bytes,tx_bytes)
  acct-<tag>.csv    (key,bytes)
Pairs: latency, down, up, recovery — each given as tag_before/tag_after.
"""
import csv
import json
import os
import sys

PAIRS = [("latency", "latency"), ("down", "down"), ("up", "up"), ("recovery", "recovery")]
ACCT_KEYS = ["client_payload_rx", "client_payload_tx",
             "transport_wire_rx", "transport_wire_tx",
             "matrix_iface_rx", "matrix_iface_tx"]


def read_iface(run_dir, tag):
    out = {}
    p = os.path.join(run_dir, "counters", f"iface-{tag}.csv")
    if not os.path.exists(p):
        return out
    with open(p) as f:
        for row in csv.DictReader(f):
            out[(row["ns"], row["iface"])] = (row["rx_bytes"], row["tx_bytes"])
    return out


def read_acct(run_dir, tag):
    out = {}
    p = os.path.join(run_dir, "counters", f"acct-{tag}.csv")
    if not os.path.exists(p):
        return out
    with open(p) as f:
        for row in csv.DictReader(f):
            out[row["key"]] = row["bytes"]
    return out


def delta(a, b):
    if a in (None, "", "NA") or b in (None, "", "NA"):
        return None
    try:
        return int(b) - int(a)
    except ValueError:
        return None


def main():
    run_dir, outfile = sys.argv[1], sys.argv[2]
    phases = {}
    for name, tag in PAIRS:
        iface_b, iface_a = read_iface(run_dir, f"{tag}_before"), read_iface(run_dir, f"{tag}_after")
        acct_b, acct_a = read_acct(run_dir, f"{tag}_before"), read_acct(run_dir, f"{tag}_after")

        iface_deltas = {}
        for key in sorted(set(iface_b) | set(iface_a)):
            ns, ifc = key
            r = delta(iface_b.get(key, ("NA",))[0], iface_a.get(key, ("NA",))[0])
            t = delta(iface_b.get(key, ("", "NA"))[1], iface_a.get(key, ("", "NA"))[1])
            iface_deltas[f"{ns}/{ifc}"] = {"rx": r, "tx": t}

        acct_deltas = {k: delta(acct_b.get(k), acct_a.get(k)) for k in ACCT_KEYS}

        # Billable Iranian physical NIC stand-in: sum of configured faces.
        phys = []
        billing = os.environ.get("BILLING_IFACE_PHYS", "wan0 tlink").split()
        for key, v in iface_deltas.items():
            ns, ifc = key.split("/", 1)
            if ns == "iran" and ifc in billing and v["rx"] is not None:
                phys.append(v["rx"])
        billable_rx = sum(phys) if phys else None

        phases[name] = {
            "window": f"{tag}_before -> {tag}_after",
            "iface_deltas": iface_deltas,
            "acct_deltas": acct_deltas,
            "billable_iran_rx": billable_rx,
        }

    json.dump({"phases": phases}, open(outfile, "w"), indent=2)
    print(outfile)


if __name__ == "__main__":
    main()
