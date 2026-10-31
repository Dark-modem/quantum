# netopt Agent-Mode & JSON Operation Contracts

Session 2 deliverable for Session 3 coordination. The Network Optimization
subsystem runs on a **lightweight Agent-only endpoint** without the full
panel configuration, and exposes six structured operations whose JSON shapes
are stable for Agent-protocol transport. **Session 3 owns the shared
protocol, routes and UI — this document is the handoff; no shared protocol
file was modified.**

## 1. What changed (the Session-6 QA defect)

`gre-panel netopt` used to boot through `cliStart()`, which requires
`/etc/gre-panel/panel.json` — absent on an Agent-only endpoint. Now:

- `netCliStart()` resolves the installation role **from the files on disk**:
  `panel.json` → controller (loads the real config via `loadOrInit`),
  `agent.json` → agent-only (the panel config is neither read nor created —
  `loadOrInit` is skipped because it would fabricate a default `panel.json`,
  the exact defect QA flagged), neither → read-only mode.
- No fake `panel.json` is ever created. A test pins this
  (`TestNetopsAgentOnlyAllOpsNoFakePanel`).
- Mutating ops (`apply`, `rollback`, `revert`, `apply-nic`) require an
  installation identity **and** root (uid 0, via the `netPrivileged` seam).
  Read-only ops (`detect`, `plan`, `status`) work everywhere — the installer
  (Session 6) may pre-flight an un-enrolled box.

## 2. Operation contracts (stable JSON)

Errors surface as Go errors to the CLI/transport; on the wire Session 3 may
wrap them — the *result payloads* below are the contract. Field names and
types are frozen; additive changes only.

### netopt.detect → NetopDetectResult

```json
{ "role": "agent",
  "report": { "kernel": "6.8.0-49-generic", "virt_type": "kvm",
              "cpu_model": "...", "cpu_cores": 4,
              "ram_total_mb": 8192, "ram_used_mb": 2048,
              "mem_available_pct": 75, "mem_pressure": false,
              "primary_iface": "eth0",
              "ifaces": [ { "name": "eth0", "kind": "physical",
                            "driver": "ixgbe", "speed_mbs": 10000,
                            "mtu": 1500, "queues_rx": 2, "rps_capable": true,
                            "ring_current": 512, "ring_max": 8192 } ],
              "sysctls": { "net.core.somaxconn": "4096", "...": "..." },
              "cc": "cubic", "cc_available": ["reno","cubic","bbr"],
              "default_qdisc": "pfifo_fast",
              "counters": { "eth0": { "rx_bytes": 0, "...": 0 } },
              "warnings": [] } }
```

### netopt.plan → NetopPlanResult

```json
{ "role": "agent", "profile": "conservative",
  "reasons": ["RAM 956 MB < 2 GB"],
  "summary": "profile=conservative apply=4 skip=3",
  "changes": [ { "key": "vm.swappiness", "kind": "sysctl",
                 "current": "60", "proposed": "10", "apply": true,
                 "reason": "keep tunnel process pages resident",
                 "risk": "more OOM risk than default on tiny boxes" },
               { "key": "net.ipv4.tcp_congestion_control", "apply": false,
                 "skip_reason": "bbr not available in this kernel" } ],
  "registry": { "…detection report…" } }
```

### netopt.apply / rollback / revert → NetopApplyResult

```json
{ "role": "agent", "op": "apply", "ok": true,
  "message": "applied profile=conservative settings=4 owned_files=1",
  "journal": { "applied_at": 1730000000, "profile": "conservative",
               "role": "agent", "reasons": ["..."],
               "applied": [ { "key": "vm.swappiness", "kind": "sysctl",
                              "before": "60", "after": "10" } ],
               "owned_files": ["/etc/sysctl.d/99-quantum-netopt.conf"],
               "verified": true, "rolled_back": false } }
```

Failure carries `ok:false` plus the journal when one exists (a rolled-back
apply keeps `rolled_back:true`, `verified:false`).

### netopt.status → NetopStatusResult

```json
{ "role": "agent", "has_journal": true, "journal": { "…as above…" },
  "drift": [ { "key": "net.core.somaxconn", "live": "9999", "wanted": "8192" } ] }
```

## 3. Guarantees kept (unchanged from the accepted subsystem)

Conservative/Balanced/Performance selection rules, no MTU/MSS tuning, no
SSH/firewall/port keys, baseline capture, owned drop-ins, read-back
validation, connectivity guard with automatic rollback, boot persistence via
the owned unit. The journal lives under `<configDir>/netopt/` — on a real
agent that is `/etc/gre-panel/netopt/` (persistent); it was never `/tmp`
in production (that path appeared only in earlier test tooling).

## 4. Handoff notes for Session 3

- Transport: the ops are plain Go functions (`NetopDetect`, `NetopPlan`,
  `NetopApply`, `NetopStatus`, `NetopRollback`, `NetopRevert` in
  `panel/netops_api.go`) returning the typed results above — wire them to
  agent-protocol messages/routes as desired. `--json` on every CLI subcommand
  already emits these exact shapes.
- Mutating ops called from the protocol must run with the agent's own root
  privileges (the agent service runs as root; the privilege seam enforces it
  for CLI paths).
- `netPlannedChange.Candidate` is intentionally `json:"-"` (unexported
  internals stay off the wire).
