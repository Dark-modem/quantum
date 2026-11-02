# Quantum Matrix Agent Lab

An isolated, reproducible test laboratory for validating the **Matrix tunnel**
(tinc-based, as deployed by `Matrix-Network-main/matrix.sh`) before its first
production deployment. Everything runs inside disposable Linux network
namespaces — the host firewall is hash-verified untouched, no production
server is ever contacted, and every lab object is named `qmx<RUNID>_*` so
cleanup can never match a production interface.

**Persian documentation: [docs/MATRIX-AGENT-LAB.md](../../docs/MATRIX-AGENT-LAB.md)**

## Layout

```
bin/labctl            single entrypoint (doctor | audit | run | dpi | clean | report)
lib/                  common, safety, netns, engine, traffic, report
scenarios/*.conf      clean, lossy2, jitter30, congested8m, satellite
suites/run_suite.sh   the 12-test measurement suite
dpi/probe.sh          DPI observation suite (facts only, no claims)
health/               60s rolling-window evaluator + proposed thresholds
schemas/              JSON report schema (draft-07)
tools/                payload server/client, probes, counters, validators
results/run-<id>/     per-run artifacts + report.json
```

## Requirements

Debian/Ubuntu root shell with: `iproute2` (netns + tc netem), `iptables`,
`tinc` (the Matrix core), `python3`, `curl`, `tcpdump` (optional, for DPI
wire observation). Runs in a VM, container, or WSL2 — the lab refuses to run
on a machine it cannot recognize as disposable unless `LAB_FORCE=1`.

## Quick start

```bash
sudo cp lab.conf.example lab.conf      # edit: billing model, payload sizes
sudo ./bin/labctl doctor               # safety + capability preflight
sudo ./bin/labctl run clean            # full 12-test suite, no impairment
sudo ./bin/labctl run congested8m      # the "stable 8 Mbps" acceptance profile
sudo ./bin/labctl dpi clean            # DPI observation suite
sudo ./bin/labctl clean                # janitor for leftovers of any run
```

Reports land in `results/run-<id>/report.json`; validate any report with
`sudo ./bin/labctl report <runid>` or `python3 tools/validate_report.py`.

## Safety contract

1. The lab **never flushes or modifies the root iptables/nftables ruleset**.
   The root firewall is snapshotted (full dump, stored per run) before the
   run and diffed after. A diff mentioning lab-named objects is a hard
   alarm; any other change is reported as external (e.g. fail2ban) with the
   line count.
2. All firewall accounting happens **inside lab namespaces only**; teardown
   removes exactly the chains the lab created.
3. tc netem shaping is applied only to lab veths inside lab namespaces —
   never to a physical NIC.
4. `labctl clean` only matches the exact `qmx<hex>_` naming scheme.

## Engine modes

* `real` — two real Matrix (tincd) instances with per-run config directories
  (`/etc/tinc` is never read or written), wired exactly like matrix.sh:
  port 2097, aes-128-cbc/md5, DNAT+MASQUERADE tunnel_helper equivalent.
* `calibration` — plain routed forward, no tunnel. Validates the accounting
  math: billable-RX amplification must come out ≈ 1.0 or the measurement
  itself is wrong. This is a control group, not a tunnel engine.
* `external` — plug in the Quantum Matrix Agent MVP via `ENGINE_CMD`
  (placeholders `{confdir} {node} {runid}`) without touching the lab.

## Traffic accounting (the key metric)

Per-direction counters inside the iran namespace (mangle chains + procfs
deltas) give, for the SAME transfer window and SAME direction:

* Iranian physical NIC RX/TX (configurable stand-in: `wan0 + tlink` summed,
  because in production both ride the provider's single NIC)
* Matrix interface (`matrix` tun) RX/TX
* Isolated application payload RX/TX (exact HTTP byte counts client-side
  and server-side, controlled 100 MiB transfers)
* Tunnel transport bytes (`tlink` carries ONLY Matrix encapsulation, by
  construction — zero contamination)

Derived: `billable RX amplification = billable Iranian RX / app payload`
and `transport overhead = Matrix transport bytes / app payload`.
`billing.model` is configurable (`interface-counter` implemented;
`provider-api`/`quota-panel` are declared UNKNOWN by the lab on purpose —
provider semantics are never guessed from interface names).

## The 12 tests

T01 startup/connectivity · T02 latency (60 s window) · T03 jitter
(RFC3550) · T04 packet loss (ICMP + UDP probe) · T05 throughput (controlled
sub-windows, stability = CV) · T06 recovery after link blackout · T07 CPU ·
T08 RAM (tincd, sampled per second) · T09 interface RX/TX · T10 transport
traffic · T11 application payload · T12 amplification.

## Honesty policy

* Unmeasurable ratios are reported as `UNKNOWN`, never estimated.
* DPI: the lab reports observable wire facts, active-probe behavior, and
  connection-reset behavior. It does NOT claim real-world DPI resistance;
  availability on the owner's approved test network is `NOT_RUN` by policy.
* Large speed tests are not part of the continuous health design; the
  future Quantum monitor uses 60 s rolling windows of cheap probes with
  asymmetric hysteresis (see `health/`).
