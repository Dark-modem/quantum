# Network Optimization — Performance Baseline, Asymmetry Analysis and Protocol

Session 2 deliverable. Reference point: **the first real Matrix tunnel**
(established successfully before this subsystem was written).

## 0. Honesty statement

This report was written **without access to the live servers** — the numbers
in §1 are the owner's reference measurements for the first real tunnel, taken
as given data. Every optimization claim in this subsystem is therefore
*conditional*: the harness in `tests/netopt/` (§4) exists to confirm or
refute each claim on the real pair, and **no optimization is claimed to
improve performance until a repeatable before/after measurement on the real
servers demonstrates it.** Nothing in the profiles was tuned against these
numbers by guesswork.

## 1. Reference measurements (as reported by the owner)

| Path | Direction | Measured |
|---|---|---|
| Matrix tunnel | A → B | 45–67 Mbit/s |
| Matrix tunnel | B → A | significantly slower than 45 Mbit/s |
| Direct path (no tunnel) | the slower tunnel direction | already showed an **egress bottleneck** |

## 2. Reading the asymmetry — what the data already rules out

The single most important fact is the third row: **the direct path already
shows an egress bottleneck in the same direction the tunnel is slow.** That
means:

- The slow direction is bottlenecked **below the tunnel**: at the sending
  host's NIC/driver, its TCP/IP stack, or the provider's egress shaping.
- The tunnel cannot be the primary cause — it inherits a path that is
  already slow in that direction. **Do not assume tinc or encryption is the
  cause.** If tunnel throughput ≈ direct throughput (per direction), the
  bottleneck is path-level, and tunnel-side tuning (CC, buffers, qdisc)
  cannot and should not "fix" it.
- The asymmetric 45–67 vs "significantly slower" split is consistent with
  the classic Iran ↔ foreign shape: one end has constrained/oversubscribed
  egress. Which end is the constrained sender is exactly what the harness
  must establish by controlled comparison (§3), not assume.

Priority order for this subsystem (from the MVP goals): **1) DPI resilience
and avoiding disruption, 2) stable latency/jitter/loss, 3) throughput,
4) low CPU/RAM, 5) Iranian billable RX efficiency.** Consequences already
reflected in the profiles: BBR+fq (better loss behavior on congested paths
without aggressive probing), calm TCP keepalives (fewer periodic probe
signatures), TFO deferred to Performance (in-SYN data raises the DPI
surface), no MTU games (fragmentation is a DPI/disruption risk).

## 3. Bottleneck isolation protocol (controlled comparison)

Run on BOTH servers, per direction, one variable at a time. The ladder
localizes the bottleneck before any tuning is proposed:

| Step | Measurement | What it isolates |
|---|---|---|
| L0 | `ethtool <nic>` both ends: link speed, duplex; `/proc/net/dev` error/drop counters before and after each run | duplex mismatch, dying NIC, carrier — the cheapest explanation for a slow direction |
| L1 | direct `iperf3 -t 30` TCP, each direction | the path's raw ceiling per direction |
| L2 | tunnel `iperf3 -t 30` TCP, each direction, **no tuning applied** (baseline) | tunnel overhead vs L1, per direction |
| L3 | repeat L2 with CPU sampling (`mpstat 1` / `/proc/softirqs` deltas) on both ends | whether the slow direction is CPU-bound at the encrypting sender |
| L4 | repeat L2 after applying **one** profile change (e.g. BBR+fq only) | the measured value of that single change |
| L5 | `netopt detect` before/after: ring drops, `tcp_mtu_probing` effects on retransmit counters (`nstat -az TcpRetransSegs`) | fragmentation/MTU contribution |
| L6 | tunnel vs NIC byte counters over the same window (the agent's traffic report already separates `physical` from `tunnel` interfaces) | overhead factor and the **billable-direction** question |

Decision rules:

- If L1(slow direction) ≈ L2(slow direction) → **path bottleneck**; do not
  touch tunnel tuning for throughput; consider it for latency/jitter only.
- If L2 < L1 in the fast direction by a large factor → tunnel overhead is
  measurable there; CPU (L3) decides between encryption cost and buffer/CC
  effects; only then does a Performance-profile candidate get evaluated.
- Every "improvement" claim requires: same time-of-day window, ≥3 runs,
  spread over ≥2 different hours, and the median compared — a single run is
  not evidence.

## 4. The harness (`tests/netopt/`)

- `baseline.sh <peer-host> [duration]` — captures L0–L3 into a timestamped
  JSON directory (detect report via `gre-panel netopt detect`, ethtool,
  counters, direct + tunnel iperf3 both directions, CPU samples).
- `compare.sh <runA> <runB>` — joins two runs into the comparison table
  (per-direction medians, tunnel/direct ratios, error counters, CPU).
- Reuses the matrix-agent-lab conventions (`counters_to_json.py`,
  scenario confs) so the lab scenarios (lossy2, jitter30, congested8m,
  satellite) remain the synthetic replay environment for the same harness.

## 5. What the profiles may and may not claim

| Change | Claim allowed | Evidence required |
|---|---|---|
| BBR+fq (Balanced) | none yet | L4 before/after on the real pair, ≥3 runs |
| Ring buffers / RPS (Performance) | none yet | L4 + CPU deltas; only where L3 shows softirq saturation |
| Calm keepalives (Balanced) | not a throughput claim — reduces periodic probe traffic on DPI'd paths (a *resilience* rationale, recorded as such) | DPI observation runs in the lab matrix |
| TFO (Performance) | no claim; explicitly deferred until DPI observation says it is safe | lab DPI prober + real-path check |
| Everything else | no claim | — |

Billable RX efficiency (priority 5): the agent's physical-vs-tunnel counters
give the overhead factor per direction; the provider's billing direction
must be confirmed with them before any "efficiency" number is published.
