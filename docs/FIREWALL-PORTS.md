# Firewall & Port Management (Session 1)

A central management model with endpoint execution for ports and firewall
rules: one place that knows which port on which transport belongs to whom,
and one engine that changes firewall state safely on the detected backend.

Status: **engine + registry + tests implemented** (`panel/firewall.go`,
`panel/portregistry.go`); the Agent-wire and HTTP-API parts of this doc are
a **proposal** to be coordinated with Session 3 (agent protocol) before any
shared file is touched.

## Ownership model

Every rule Quantum creates is identifiable:

| Backend | Quantum-owned artifact | Per-rule identity |
|---|---|---|
| ufw | — (ufw owns the ruleset) | comment `quantum:<owner>`, e.g. `quantum:tunnel:at_1a2b3c4d` |
| iptables (legacy or nf_tables compat) | chain `QUANTUM_FW` + one commented jump `INPUT → QUANTUM_FW` (`--comment quantum-fw`) | rule comment `quantum:<owner>` inside the chain |
| nftables (native) | none — Quantum **refuses to mutate** a foreign ruleset | read-only snapshots only |

Three rule classes are distinguished everywhere:

1. **Quantum-owned** — only the artifacts above; deletions match them
   exactly (rule spec for iptables, exact port/proto + presence guard for
   ufw).
2. **Administrator-managed** — never modified; verified preserved by
   tests (hermetic + lab).
3. **Unrelated applications** — detected via listeners (`ss -Htulnp`)
   and reported as conflicts, never touched.

`owner` is `<kind>:<id>` with kind `tunnel | service | external`.

## Backend detection (never assume; never mix)

`fwDetect()` probes in this order and manages exactly ONE backend:

1. `ufw status` → `Status: active` ⇒ **ufw** (ufw owns the whole
   ruleset; its iptables/nft output is ufw's, so it wins).
2. `iptables -S` succeeds ⇒ **iptables** (the `--version` detail records
   whether it is the nf_tables compatibility layer).
3. `nft list tables` succeeds ⇒ **nftables (native, read-only)**.
4. none ⇒ registry-only mode (reservations still work; rule plans are
   refused with a clear message).

Why the native-nftables case refuses: in nftables, several base chains on
the same hook are all traversed — an `accept` in Quantum's own chain does
not override a drop in the administrator's chain. Opening a port safely in
someone else's nftables ruleset requires editing that ruleset, which
breaks the ownership model. The refusal names the alternatives (UFW, or
the administrator adds the rule).

## Safety invariants (enforced by a hard refusal layer)

`fwForbidden()` is checked before EVERY execution — even a bug in a
command builder cannot run:

- `ufw reset`
- `iptables/-6 -F` / `-X` with anything other than `QUANTUM_FW`
- any NAT-table flush (`-t nat … -F`)
- `nft delete table …`, `nft flush ruleset`

Chain creation is additive and idempotent (`-N`, one commented jump);
teardown of a tunnel removes only rules tagged `quantum:<that tunnel>`.

## Port registry (`port_registry.json`, 0600)

- Entries: `port`, `proto (tcp|udp)`, `owner_kind`, `owner_id`, `family`,
  `note`, `reserved_at`. Atomic tmp+rename writes, `.bad` quarantine on
  corruption — same durability pattern as `agent_tunnels.json`.
- **TCP and UDP are independent namespaces** — availability is checked
  per transport against `ss -Htulnp` listeners, and every port report
  shows the sibling transport's usage (a free TCP port with a live UDP
  listener is the classic trap this exposes).
- A port inside the kernel ephemeral range
  (`/proc/sys/net/ipv4/ip_local_port_range`) can never be reserved.
- Reservation is refused while a foreign process already listens on the
  port; idempotent for the same owner; a conflict error for another.
- `portConflicts()` reports registry entries held by a live
  non-Quantum process.
- Operations: `portReserve / portRelease / portReleaseOwner /
  portEntries / portEntriesForOwner / portAvailabilityCheck /
  portReport / portConflicts / portListeners`.

## Engine operations (`firewall.go`)

`fwDetect` · `fwCaptureSnapshot` · `fwNewPlan` · `fwPlanAddOwner` ·
`fwPlanRemoveOwner` · `fwApply` · `fwTeardownOwner` · `fwForbidden`.

- **Dry-run**: `fwPlan{DryRun:true}` returns the exact argv without
  executing anything.
- **Before/after snapshots** of the live ruleset on every real apply.
- **Rollback**: applied steps carry their inverse commands; the first
  failure rolls the plan's OWN steps back in reverse (never foreign
  state) and records `rolled_back` in the audit entry.
- **Audit history**: append-only `<configDir>/firewall_audit.jsonl` —
  timestamp, plan id, backend, ops, executed commands, before/after
  raw ruleset, error, rolled-back count.

## Typed Agent execution interface (IMPLEMENTED — `panel/firewall_agent.go`)

Narrowly typed, validated, no shell escape hatch. The handlers below are
the EXACT contract Session 3 can register in the agent dispatcher /
controller command allowlist; this file deliberately does not touch
`agentproto.go`, `agent.go` or the route tables. Suggested registration:

```go
// dispatcher registration (Session 3):
//   "fw.detect"   → AgentFirewallDetect()
//   "fw.snapshot" → AgentFirewallSnapshot()
//   "fw.plan"     → AgentFirewallPlan(p fwAgentPlanParams)
//   "fw.apply"    → AgentFirewallApply(p fwAgentApplyParams)
//   "fw.teardown" → AgentFirewallTeardown(p fwAgentTeardownParams)
//   "port.check"  → AgentPortCheck(p fwAgentPortCheckParams)
//   "port.list"   → AgentPortList()
```

| Op | Params (JSON) | Result (JSON) | Errors |
|---|---|---|---|
| `fw.detect` | — | `{backend, detail}` | never (backend may be `none`) |
| `fw.snapshot` | — | `{backend, at, raw}` | backend read failure |
| `fw.plan` | `{owner "kind:id", family?, note?, add[]: {port,proto}, remove[]: {port,proto}}` | `{plan, planned_cmds, refusal?}` — ALWAYS dry-run, executes nothing | invalid owner/proto/port, nothing to plan; backend refusal lands in `refusal` |
| `fw.apply` | `{ops[], confirmed}` | `fwApplyResult` | `confirmed != true` refused; engine validators; partial failure rolls back |
| `fw.teardown` | `{owner "kind:id", confirmed}` | `{released_ports, firewall: fwApplyResult}` | `confirmed != true`; firewall removal runs FIRST (registry-driven), release second — a failed removal stays retriable |
| `port.check` | `{port, proto?}` | availability report, or both-transports report when proto omitted | bad port/proto |
| `port.list` | — | `{backend, detail, entries[], listeners[], conflicts[]}` | — |

Owner tags are `kind:id` with kind `tunnel|service|external`; ids with
quotes or shell metacharacters are rejected before anything runs.

## CLI reference (IMPLEMENTED — `panel/firewall_cli.go`)

```
gre-panel firewall detect                       → {"backend","detail"}
gre-panel firewall snapshot                     → {"backend","at","raw"}
gre-panel firewall plan  --owner T --add 443/tcp [--add 53/udp] [--family both] [--note N]
                                                → dry-run result JSON (planned_cmds) — NEVER mutates
gre-panel firewall apply --owner T --add 443/tcp --yes
                            [--plan-file plan.json]
                                                → fwApplyResult (refuses without --yes)
gre-panel firewall teardown --owner tunnel:at_x --yes
                                                → {"released_ports","firewall"}
gre-panel ports list                            → {"backend","detail","entries","listeners","conflicts"}
gre-panel ports check 443[/tcp|/udp]            → both-transports report / one transport
```

Exit codes: 0 ok · 1 runtime error (`{"error":…}`) · 2 usage. `--plan-file`
applies the exact ops a previously reviewed plan carried (re-validated by
the engine anyway).

## Controller UI contract (JSON schemas for Session 3)

`fwApplyResult` is the shared shape for dry-run plan, apply result and
rollback result:

```json
{
  "plan": { "id": "fw_ab12cd34", "backend": "iptables", "dry_run": true,
            "ops": [ { "kind": "add",
                       "rule": { "port": 443, "proto": "tcp", "family": "both",
                                  "owner": "tunnel:at_1a2b3c4d", "note": "" } } ] },
  "before": { "backend": "iptables", "at": 1730000000, "raw": "-P INPUT accept\n…" },
  "after":  { "backend": "iptables", "at": 1730000005, "raw": "…" },
  "applied": [ { "op": { "kind": "add", "rule": { … } },
                 "cmds":  [ ["iptables","-A","QUANTUM_FW","-p","tcp","--dport","443","-m","comment","--comment","quantum:tunnel:at_1a2b3c4d","-j","ACCEPT"] ],
                 "undo":  [ ["iptables","-D","QUANTUM_FW","…"] ],
                 "skipped": false } ],
  "planned_cmds": [ ["…"] ],
  "rolled_back": 0,
  "error": ""
}
```

- **Firewall overview** (`GET /api/firewall` proposal): `{backend, detail,
  conflicts: [{port, proto, owner, listener}], audit_tail: [fwAuditEntry…]}`.
- **Listening ports** (`GET /api/ports`): `{backend, detail, entries:
  [portEntry], listeners: [{proto, port, address, process, pid}],
  conflicts: […]}`.
- **Owner-tagged rules** (`GET /api/ports?owner=tunnel:at_x`):
  registry entries of that owner + their applied firewall rules from the
  last audit entry.
- **Dry-run plan** (`POST /api/firewall/plan` body = `fwAgentPlanParams`):
  `fwAgentPlanResult` — the UI shows `planned_cmds` and MUST send the same
  ops to apply.
- **Apply result** (`POST /api/firewall/apply` body = `fwAgentApplyParams`
  with `confirmed:true`): `fwApplyResult`.
- **Rollback result**: the same `fwApplyResult` — a rolled-back apply is
  identified by `rolled_back > 0` and `error != ""`; the audit entry
  carries the before/after snapshots proving the restore.

Suggested endpoints (Session 3 wires them; handlers are one-liners over
the functions above): `GET /api/firewall`, `GET /api/ports`,
`GET /api/ports/{port}`, `POST /api/firewall/plan`,
`POST /api/firewall/apply`, `POST /api/firewall/teardown` — all under
`requireAuth` + `requireCSRF`, errors via new `E-FW-*` codes.

## API integration proposal (controller side)

Route registrations for `panel/main.go` (not added yet — shared file):

```
GET  /api/firewall            → backend, quantum rules, conflicts, audit tail
GET  /api/ports               → registry entries + live listeners
GET  /api/ports/{port}        → both-transports report
POST /api/firewall/plan       → body {ops[]} → dry-run result (planned cmds)
POST /api/firewall/apply      → body {plan_id} → execute a previously planned id
POST /api/tunnels/{id}/teardown → registry release + fwTeardownOwner (tunnel deletion hook)
```

All under `requireAuth` + `requireCSRF`, errors via new `E-FW-*` codes in
`errors.go`. Tunnel-deletion integration point: call
`portReleaseOwner("tunnel", id)` + `fwTeardownOwner("tunnel:"+id)` next to
the existing topology/agent-tunnel delete paths.

## Legacy provisioning script — what was kept and what was rejected

Reviewed `quantum.sh` (the owner's current installer) and the older
`matrix-network` script:

**Preserved behavior**
- Per-port `ufw allow <port>/tcp|udp` — the engine generates exactly
  these, but tagged with `quantum:<owner>` comments and tracked in the
  registry (quantum.sh:1037, 2878-2879, 4265…).
- Owned-chain hygiene: quantum.sh flushes only its OWN `QUANTUM-DPI`
  chain (`iptables -F QUANTUM-DPI; iptables -X QUANTUM-DPI`,
  quantum.sh:3279-3280) — chain-scoped, never global. The engine follows
  the same discipline and additionally refuses global ops by code.
- Kernel reserved-port protection (`ip_local_reserved_ports`) and the
  ephemeral-range awareness behind port allocation.

**Rejected behavior (never ported)**
- `iptables -t nat -F` — the matrix-network script's global NAT flush
  destroys every pre-existing rule on the host (its line 1078).
- Any whole-ruleset replacement or `ufw reset`.
- Un-commented, untracked rules: every Quantum rule is now
  owner-identifiable and audited.

## Tests

- **Hermetic** (any OS): `firewall_test.go` (13) + `portregistry_test.go`
  (10) — detection order (ufw > iptables-compat > nft > none), exact argv
  for ufw/iptables, add/remove idempotency, unrelated-rule preservation,
  the forbidden-command refusal layer, rollback after partial failure,
  tunnel-only teardown via the registry, nft refusal, audit snapshots,
  reserve/release idempotency + conflicts, TCP/UDP independence,
  ephemeral-range refusal, live-listener refusal, process-ownership
  parsing, **two simultaneous allocations (exactly one winner)**, and
  both-transports reporting.
- **Linux lab** (real kernel, disposable netns):
  `tests/test_firewall_lab.sh` → builds the test binary, creates namespace
  `fwlab-$$`, runs `TestFirewallLab*` inside it: real iptables lifecycle
  (chain + jump + both families + admin-rule preservation), real listener
  conflicts with real sockets, real nft reads, ufw detection when
  present. Skips cleanly when root/tools are missing.
