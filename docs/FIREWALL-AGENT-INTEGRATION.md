# Firewall/Port Agent Integration — contract for Session 3

Session 1 delivers the engine and these handlers; Session 3 wires them
into the shared protocol. This document is the single source of truth for
that wiring. Nothing in `agentproto.go`, `agent.go` or the route tables
was changed by Session 1.

Implemented at: `panel/firewall_agent.go` (handlers), `panel/firewall.go`
(engine), `panel/portregistry.go` (registry), verified by
`panel/firewall_agent_readiness_test.go` (all seven handlers, JSON
round-trips, safety semantics).

## 1. Dispatcher registration (exact)

Every handler is a plain Go function returning typed results; the only
adapter needed is a JSON envelope. Suggested registration in the agent
command dispatcher:

```go
// fw ops → handlers (no shell, no string commands; params are JSON).
"fw.detect":   func(json.RawMessage) (any, error) { return AgentFirewallDetect(), nil },
"fw.snapshot": func(json.RawMessage) (any, error) { return AgentFirewallSnapshot() },
"fw.plan":     func(raw json.RawMessage) (any, error) {
    var p fwAgentPlanParams
    return AgentFirewallPlan(p), nil // parse errors surface as handler errors
},
"fw.apply":    func(raw json.RawMessage) (any, error) {
    var p fwAgentApplyParams
    return AgentFirewallApply(p), nil
},
"fw.teardown": func(raw json.RawMessage) (any, error) {
    var p fwAgentTeardownParams
    return AgentFirewallTeardown(p), nil
},
"port.check":  func(raw json.RawMessage) (any, error) {
    var p fwAgentPortCheckParams
    return AgentPortCheck(p), nil
},
"port.list":   func(json.RawMessage) (any, error) { return AgentPortList() },
```

Adapter rule for `agentCommandResult`: `OK = (err == nil)`,
`Output = json(result)`, `Error = err.Error()`.

## 2. Function signatures (exact, at commit 479d745/b9e4e39+)

```go
func AgentFirewallDetect() fwAgentDetectResult
func AgentFirewallSnapshot() (fwSnapshot, error)
func AgentFirewallPlan(p fwAgentPlanParams) (fwAgentPlanResult, error)
func AgentFirewallApply(p fwAgentApplyParams) (fwApplyResult, error)
func AgentFirewallTeardown(p fwAgentTeardownParams) (fwAgentTeardownResult, error)
func AgentPortCheck(p fwAgentPortCheckParams) (any, error)
func AgentPortList() (fwAgentPortListResult, error)
```

## 3. Request/response schemas (JSON)

### fw.detect
```json
→ {}   ← {"backend":"iptables|ufw|nftables|none","detail":"iptables v1.8.10 (nf_tables)"}
```

### fw.snapshot
```json
→ {}   ← {"backend":"iptables","at":1730000000,"raw":"-P INPUT accept\n…"}
```

### fw.plan — ALWAYS dry-run; executes nothing on the host
```json
→ {"owner":"tunnel:at_1a2b3c4d","family":"both","note":"…",
   "add":[{"port":443,"proto":"tcp"}],
   "remove":[{"port":53,"proto":"udp"}]}
← {"plan":{"id":"fw_ab12cd34","backend":"iptables","dry_run":true,"ops":[…]},
   "planned_cmds":[["iptables","-A","QUANTUM_FW","-p","tcp","--dport","443",
                    "-m","comment","--comment","quantum:tunnel:at_1a2b3c4d","-j","ACCEPT"]],
   "refusal":""}
```
`refusal` is set (and the call errors) when the backend is native
nftables or none: the engine refuses foreign-ruleset mutations by design.

### fw.apply — requires `confirmed:true` (the controller saw a dry-run)
```json
→ {"ops":[{"kind":"add","rule":{"port":443,"proto":"tcp","family":"both",
          "owner":"tunnel:at_1a2b3c4d","note":""}}],
   "confirmed":true}
← fwApplyResult: {"plan":{…},"before":{…},"after":{…},
                  "applied":[{"op":{…},"cmds":[…],"undo":[…],"skipped":false}],
                  "rolled_back":0,"error":""}
```
A partial failure rolls the plan's OWN applied steps back in reverse and
returns `rolled_back>0` with `error` set — the caller shows both.

### fw.teardown — requires `confirmed:true`
```json
→ {"owner":"tunnel:at_1a2b3c4d","confirmed":true}
← {"released_ports":2,"firewall":{ fwApplyResult }}
```
Order is fixed: firewall rules first (the registry is the plan's source
of truth), registry release second — a failed rule removal stays
retriable. Only rules/comments tagged `quantum:<owner>` are removed.

### port.check
```json
→ {"port":8443,"proto":"tcp"}          ← {"port":8443,"proto":"tcp","available":false,
                                          "reason":"tcp listener present (xray, pid 9)",
                                          "listener":{…},"other_transport":""}
→ {"port":8443}                        ← {"port":8443,"tcp":{…},"udp":{…}}
```

### port.list
```json
→ {}   ← {"backend":"iptables","detail":"…","entries":[portEntry],
          "listeners":[{proto,port,address,process,pid}],"conflicts":[…]}
```

## 4. Error mapping

| Condition | Go error text (substring to match) | Dispatcher mapping | Suggested panel code |
|---|---|---|---|
| apply/teardown without `confirmed` | `confirmed=true` | `OK:false` | `E-FW-01` (confirmation required) |
| empty plan | `nothing to plan` | `OK:false` | `E-FW-02` |
| native nftables / no backend | equals `fwErrNftForeign.Error()` (`native nftables backend: …`) | `OK:false` + `refusal` in plan result | `E-FW-03` (foreign ruleset) |
| bad port/proto/owner | `out of range` / `proto must be` / `owner must be` / `owner id must not` | `OK:false` | `E-FW-04` (validation) |
| port reserved by another owner | `already reserved by` | `OK:false` | `E-FW-05` |
| port held by a live foreign process | `already in use by` | `OK:false` | `E-FW-06` |
| inside kernel ephemeral range | `ephemeral range` | `OK:false` | `E-FW-07` |
| backend command failure (after auto-rollback) | wrapped `[…]: exit status N` | `OK:false` + fwApplyResult in Output | `E-FW-08` |
| unknown owner kind shape | `owner must be kind:id` / `owner kind must be` | `OK:false` | `E-FW-04` |

All refusals are plain `error` values with stable substrings above; the
engine also writes every real apply (success or failure) to
`firewall_audit.jsonl` with before/after snapshots.

## 5. Authorization requirements

- **Endpoint side:** the ops run inside the agent, which already
  authenticates the controller session (agent key, constant-time hash
  compare, TOFU TLS pin; revocation kicks live sessions). The mutating
  ops add a second gate: `confirmed:true`, which the controller sets ONLY
  after the operator approved a dry-run through the authenticated panel.
- **Controller side:** the proposed HTTP endpoints
  (`POST /api/firewall/plan|apply|teardown`, `GET /api/firewall`,
  `GET /api/ports[/{port}]`) must sit behind `requireAuth` +
  `requireCSRF` like every other mutating route; plan is read-only but
  still session-gated. Every mutation lands in the engine audit trail.
- **Never** expose these handlers through any shell/string-command path;
  the allowlist must map only the seven op names above.

## 6. installer-lib.sh (Session 6) — review findings

Reviewed `installer-lib.sh` @ `e5206a4` (read-only; Session 6 owns it).

**Conforms:** additive-only changes; ownership comments
(`quantum:<role>:<name>`); UFW detection mirrors the engine's
(`Status: active`); native-nftables hosts get an explicit "enforcement is
owned by the firewall engine" warning instead of a foreign write; SSH
bootstrap preserves existing ports/keys with `sshd -t` gating, drop-in
restore and a full socket-migration rollback; nginx/SSH rules are never
flushed (no reset/flush exists anywhere in the file).

**Three integration notes for Session 6 (no code changed by Session 1):**
1. **Engine probe now works:** `fw_engine_available` runs
   `gre-panel firewall --help` — Session 1 made an explicit `--help` exit
   0 (commit this round), so the probe detects the engine correctly.
2. **Recommended takeover shim:** when `fw_engine_available` is true, the
   installer should route openings through the engine so rules land in
   the owned `QUANTUM_FW` chain (installer INPUT-inserts are invisible to
   engine teardown):
   ```bash
   gre-panel firewall plan  --owner "$role:$name" --add "$port/$proto" --note "installer"
   gre-panel firewall apply --owner "$role:$name" --add "$port/$proto" --yes --note "installer"
   ```
   (and record the port into the registry via a future `ports reserve`
   subcommand if per-owner release is wanted).
3. **Owner-tag namespace:** installer tags are `quantum:<role>:<name>`
   (three segments). The engine's teardown contract accepts that shape
   as owner `<role>:<name>` (commit this round relaxed the kind
   validation to any lowercase word); the REGISTRY keeps its stricter
   enum (tunnel|service|external) for reservations. Removal helper
   (`fw_remove_port`) does not exist yet in installer-lib.sh — until one
   exists, the engine's `firewall teardown --owner <role>:<name> --yes`
   is the designated remover for installer rules.
