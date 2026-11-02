# Network Optimization measurement harness (tests/netopt)

Run on the REAL Controller/Agent pair — this harness is the evidence layer
for docs/NETOPT-PERF.md. Nothing here is a simulation: it captures live
detection, NIC facts, counters and per-direction throughput before and after
any `netopt apply`.

## Commands

On BOTH servers (the peer runs `iperf3 -s`):

```bash
tests/netopt/baseline.sh <peer-host> 30     # -> runs/<timestamp>-<host>/
```

After a change (e.g. `gre-panel netopt apply`), run the same command again,
then on the aggregator side:

```bash
python3 tests/netopt/compare.py runs/<runA> runs/<runB>
```

## What a run captures

- `detect.json` — the full `gre-panel netopt detect` report (hardware, sysctls,
  counters at time zero)
- `ethtool-primary.txt` — link speed/duplex of the primary NIC (L0)
- `proc-net-dev.before/after` — cumulative counters around the measurement
  window (errors/drops + byte accounting for the billable-direction question)
- `direct-*.json`, `tunnel-*.json` — iperf3 TCP, both directions, 3 runs each
  (L1/L2 of the isolation ladder)
- `cpu-during-*.txt` — /proc/stat samples during tunnel runs (L3)
- `nstat.after` — retransmit counters (L5, MTU/fragmentation contribution)

## Rules (from docs/NETOPT-PERF.md)

- One variable between runA and runB (one profile, one apply).
- Same time-of-day window; spread runs across ≥ 2 different hours; medians.
- No "improvement" claim without a repeatable before/after delta.
- Tunnel ≈ direct in a direction → the bottleneck is the path, not the
  tunnel; tunnel tuning for throughput there is wrong by definition.
