# AGENT-RECOVERY-AUDIT — Matrix Agent MVP: Failure Recovery & Reliability

Session 1 independent reliability audit (no production-code changes; defect-
pinning tests only). Companion test file: `panel/agent_recovery_audit_test.go`.

## 1. Identity of what was reviewed

| | |
|---|---|
| Repository | `C:/Users/-Mahdi/AppData/Local/Temp/quantum-ref` (origin: `github.com/Dark-modem/quantum`) |
| Branch under review | `feature/agent-matrix-mvp` |
| Base SHA (recorded, pinned) | `2e1ea25eae161d1a4b576e9e4583c07a8cb279b3` ("Controller-side protocol security tests") |
| Audit worktree | `C:/Users/-Mahdi/AppData/Local/Temp/wt-s1-recovery`, branch `wt/agent-recovery-audit`, created from the pinned SHA |
| Shared worktrees touched | none (`wt/agent-a…f`, `wt/agent-scale`, and the main worktree were only read) |
| Scope boundary | Controller side only (`agent_topology.go`, `agenthub.go`, `agentreg.go`, `agentproto.go`, `agentwire.go`). The headless agent runtime, installer scripts, nginx, frontend and Matrix Lab files were NOT opened or modified per the task rules. |

Changed files in this audit worktree (both new, nothing else touched):

1. `panel/agent_recovery_audit_test.go` — 8 failure-injection tests pinning current behavior.
2. `docs/AGENT-RECOVERY-AUDIT.md` — this report.

## 2. How the MVP actually works (ground truth for the scenarios)

- Desired state is persisted **per agent** in `agents.json`
  (`agentRecord.Desired`, `panel/agentreg.go:50`) and pushed over the agent
  WebSocket. Delivery to an offline agent is **not an error**: the state is
  stored and re-sent on the agent's next connect
  (`agenthub.go:548-580`, `agenthub.go:206-209`).
- Each agent record holds exactly **one** pending desired slot — a later
  delivery silently replaces an unacked one (`agentHubDeliverDesired`,
  `agenthub.go:556-562`).
- An OK ack clears the pending slot (`handleAck`, `agenthub.go:439-470`);
  stale/duplicate acks are ignored.
- Tunnel lifecycle states persist in `agent_tunnels.json`:
  `provisioning → registering → active`, plus `stopped`/`error`
  (`agent_topology.go:83-89`).
- `agentTunnelProvision` (`agent_topology.go:318-453`) is a fire-once
  goroutine: hub desired → wait ack → build node bundle → node desired →
  wait ack. Every failure lands in `state=error` via `fail()`
  (`:347-359`). It is **never re-run by anything**: the only caller is the
  create handler (`:747`); nothing scans the store at startup
  (`wireAgentSubsystem`, `agentwire.go:48-55`, contains no reconcile).
- Deletion (`handleAgentTunnelDelete`, `agent_topology.go:858-894`) removes
  the record **first**, then fires two best-effort `remove` desired states
  in fresh goroutines (`:886-891`); delivery errors are discarded.
- The ack observer (`agentTunnelAckObserved`, `:211-245`) matches acks to
  records by persisted revision. For the hub side it records only
  `OK/Error` — `ack.Detail["main_host"]` is persisted solely inside
  `agentTunnelProvision` (`:381-389`).

## 3. Scenario results (deliverable 2)

Labels: CONFIRMED = read directly in source; MEASURED = reproduced by the
named test in this worktree; UNKNOWN = not decidable here.

| # | Scenario | Expected (ideal) | Actual behavior today | Evidence | Test (MEASURED) |
|---|---|---|---|---|---|
| S1 | Partial provisioning: hub ok, node fails | Roll back or clearly resumable hub-side state | Tunnel → `error`; **no rollback desired is ever sent to the hub** (instance, tinc config, DNAT ports keep running); no retry path exists; instance stays allocated while the record lives | `fail()` `agent_topology.go:347-359`; no caller of provision except create (`:747`) | `TestAgentRecoveryS1PartialProvisioningNoRollback` — PASS (pins defect) |
| S2 | Offline deletion (agent disconnected) | Teardown retained, applied on reconnect, record freed only after confirmation | **Split verdict.** Good: the `remove` desired is retained in `agents.json` and delivered on next connect (hub layer). Bad: (a) the tunnel record is deleted instantly, so the controller forgets the tunnel before teardown is confirmed; (b) the single desired slot means **any later desired to that agent clobbers the pending teardown**; (c) the instance name is freed immediately and reused | retain/redeliver: `agenthub.go:548-580,206-209`; slot overwrite: `:556-562`; instant record removal: `agent_topology.go:871-880`; free instance: `:168-181` | `TestAgentRecoveryS2OfflineDeleteRetainedThenClobbered`, `TestAgentRecoveryS4InstanceReuseWhileTeardownPending` — PASS (pin both halves) |
| S3 | Controller restart with records in `provisioning` / `registering` / `error` | Resume or fail-fast with a reachable retry | **No startup reconciliation exists.** `provisioning` dead-ends: a late hub ack sets `HubAckOK` but the observer **drops `Detail["main_host"]`**, so even the data needed to resume is lost; `registering` completes only **incidentally** if the agent re-acks the same revision (revision match in the observer); `error` is never retried. In-memory ack-wait channels are lost (by design; registry redelivery is the real recovery path) | no reconcile: `agentwire.go:48-55`; observer drops detail: `agent_topology.go:224-227`; host file stored only in provision: `:381-389`; incidental node-ack flip: `:228-237` | `TestAgentRecoveryS3RestartProvisioningDeadEnd`, `TestAgentRecoveryS3RestartRegisteringRecoversViaLateAck` — PASS |
| S4 | Idempotency (duplicate applies/instances/rules) | Same operation twice = same result | Store-level allocation is race-free (mutex-held `NextInstance`+save); duplicate acks are harmless no-ops; **BUT** deleting a tunnel while its provisioning goroutine is mid-flight lets the node desired for the *deleted* tunnel still be delivered → an agent-side instance **no controller record can ever clean**; and the instance name is reused while the old teardown may still be pending (pairs with S2b) | delete race: `agent_topology.go:858-894` vs provision stages `:366-451` (record re-checked **nowhere** between stages) | `TestAgentRecoveryS4DeleteDuringProvisioningOrphans`, `TestAgentRecoveryS4DuplicateAckIdempotent` — PASS |
| S5 | Agent reconnect convergence | Apply latest desired, never stale intermediates | Correct at controller level: single pending slot = last-write-wins; reconnect delivers only the latest revision; equal-revision redelivery is stable. Agent-side stale-revision rejection is documented (`docs/AGENT-CONTROLLER.md`) but the runtime was out of scope → agent behavior itself UNKNOWN here | slot semantics: `agenthub.go:548-580`; redelivery: `:206-209`; doc: `AGENT-CONTROLLER.md:83-85` | `TestAgentRecoveryS5ReconnectLatestWins` — PASS (pins the good behavior) |

## 4. Reproducible failures (deliverable 3)

All reproduced in-process against the pinned SHA with seam fakes / the real
registry path (no live agents, no host changes):

1. **F1 (HIGH) — Delete/provision race orphans the node instance.**
   `handleAgentTunnelDelete` while `agentTunnelProvision` is between the hub
   ack and the node delivery → node applies a bundle for a record that no
   longer exists. No API can later remove it (the record is gone; the next
   create allocates a *different* instance name).
2. **F2 (HIGH) — Pending teardown is clobberable + instance freed early.**
   Offline delete: the `remove` desired sits in `agents.json`; any later
   desired for the same agent (e.g. provisioning a new tunnel that reused
   the freed instance name) **replaces** it before the agent reconnects →
   the old instance (service + DNAT) is never torn down.
3. **F3 (HIGH) — Controller restart dead-ends `provisioning` records.**
   No reconcile at startup; additionally the late hub ack loses
   `main_host` (observer ignores `Detail`), so a resume cannot even rebuild
   the node bundle without re-applying to the hub.
4. **F4 (MEDIUM) — Partial provisioning has no rollback and no retry.**
   Node failure leaves the hub running; the only cleanup is a manual full
   delete (which today is itself subject to F1/F2).
5. **F5 (LOW)** — `agentTunnelPowerRestart` happily issues
   matrix.start/stop for records in `provisioning`/`registering` (instance
   may not exist agent-side). Confusing, not corrupting.
6. **F6 (LOW, observation)** — `saveAgentTunnels` is a non-atomic
   `.tmp`+rename under a shared mutex; a transient Windows rename lock
   surfaced as `Access is denied` in the S1 test log. Callers log-and-
   continue; on Linux this is a non-issue. Cited for completeness.

Not defects (verified good): registry retention/redelivery of desired state
(S2 good half, S5), duplicate-ack immunity (S4), 0600 store files, and the
"healthy = real mesh ping" verification model.

## 5. Minimal recommended fixes (deliverable 4 — ordered by severity)

No production code was changed; these are the smallest safe shapes.

1. **F3 — startup reconciliation (HIGH).** One function, called once from
   the controller path (e.g. end of `wireAgentSubsystem`): scan
   `agent_tunnels.json`; for records in `provisioning`/`registering`/`error`
   with `Active`, re-run `agentTunnelProvision(id)` (it re-delivers with
   fresh revisions; agents already treat equal/stale revisions as
   idempotent/refused). Also persist `ack.Detail["main_host"]` in
   `agentTunnelAckObserved`'s hub branch so a post-restart ack keeps the
   resume data. Cost: ~30 lines, fully seam-testable.
2. **F1 — re-check the record between provisioning stages (HIGH).** After
   the hub ack (and before any node delivery / store write), reload the
   store; if the tunnel record vanished or was deactivated, abort and
   best-effort deliver `remove` for the instance to both agents. ~15 lines.
3. **F2 — tombstones + teardown-safe desired slot (HIGH).** On delete,
   keep the record with `state=deleting` (it keeps reserving the instance
   in `agentTunnelNextInstance`) until both agents ack the remove (or a
   TTL sweep, e.g. 24h, frees it). Because the registry holds a single
   desired slot per agent, also either (a) queue per-instance Matrix
   actions instead of one slot, or (b) suppress new desired delivery to an
   agent whose pending `remove` is unacked. (a) is the correct shape; (b)
   is the two-line guard.
4. **F4 — resume instead of dead error (MEDIUM).** Reuse F3's reconcile as
   an explicit "retry provisioning" action on `error` records; optionally
   auto-rollback the hub side after N failed node attempts (send `remove`
   to the hub, mark `state=error` with `rolled_back=true`).
5. **F5 — guard power/restart for non-active records (LOW)** — reject with
   `E-AGENT-05` while `state ∈ {provisioning, registering}`.
6. **F6 — optional:** retry-once around the `saveAgentTunnels` rename.

## 6. Test evidence (deliverable 5 inputs)

Toolchain: portable Go at `C:/Users/-Mahdi/AppData/Local/Temp/go/bin`
(`go version go1.23.4 windows/amd64`); module `panel/go.mod`.

```
$ cd C:/Users/-Mahdi/AppData/Local/Temp/wt-s1-recovery/panel
$ gofmt -l agent_recovery_audit_test.go            # (no output — clean)
$ go vet .                                          # (no output — clean)
$ go test -run 'TestAgentRecovery' -v -count=1 .
--- PASS: TestAgentRecoveryS1PartialProvisioningNoRollback (0.10s)
--- PASS: TestAgentRecoveryS2OfflineDeleteRetainedThenClobbered (0.06s)
--- PASS: TestAgentRecoveryS3RestartProvisioningDeadEnd (0.03s)
--- PASS: TestAgentRecoveryS3RestartRegisteringRecoversViaLateAck (0.03s)
--- PASS: TestAgentRecoveryS4DeleteDuringProvisioningOrphans (2.08s)
--- PASS: TestAgentRecoveryS4InstanceReuseWhileTeardownPending (0.05s)
--- PASS: TestAgentRecoveryS4DuplicateAckIdempotent (0.04s)
--- PASS: TestAgentRecoveryS5ReconnectLatestWins (0.07s)
ok  	github.com/pdnczone/quantum-panel/panel	2.611s
$ go test -run 'TestAgent' -count=1 .               # full agent suite incl. existing tests
ok  	github.com/pdnczone/quantum-panel/panel	5.725s
```

Note: `gofmt -l .` flags `topology.go` and `topology_list_layout_test.go` —
both are pre-existing at the base SHA (Session 3's files, untouched here).

## 7. Verdict (deliverable 5)

**Can the Matrix MVP safely recover from Agent disconnection and Controller
restart today? Not yet — it is safe for attentive manual operation, not for
unattended recovery.**

- The **transport layer is sound**: desired state survives controller
  restarts (registry) and agent disconnects (redelivery on connect), and
  revision semantics give apply-flows idempotent convergence (S5, S2-good
  half — CONFIRMED + MEASURED).
- The **orchestration layer is where recovery breaks** (MEASURED): offline
  deletion can be silently cancelled by the next desired (F2), a delete
  during in-flight provisioning orphans agent-side instances (F1), a
  restart parks `provisioning` tunnels forever (F3), and partial
  provisioning never rolls back (F4).
- All four high/medium gaps have small, seam-testable fixes (section 5);
  F1–F3 are each ≤ ~30 lines in `agent_topology.go` / `agenthub.go` /
  `agentwire.go` and none require a protocol change. Recommend landing
  F3 → F1 → F2 (in that order) before any real-agent deployment, with the
  pinning tests in `agent_recovery_audit_test.go` flipped to assert the
  repaired behavior as each fix lands.

Nothing was pushed, tagged, released, or deployed; no shared worktree,
branch of another session, or production-code file was modified.

---

## Implementation addendum (Session 1 fix round)

Baseline implemented against: `feature/agent-matrix-mvp` @ `9984cffdc5e2f8c8744cca2ff189aed69887bddb`
("Release v1.28.0 in source: the Matrix agent MVP"). Verified that the
controller-side files audited above are byte-identical between the audit
base `2e1ea25` and `9984cff` (the merge only added the agent runtime,
installer and one e2e test), so every finding applied verbatim. The fixes
live on branch `wt/agent-recovery-fix` (this worktree) — not merged into
Session 3's branch. The agent runtime (`agent.go`, `agent_state.go`, …),
installers, frontend, nginx and Matrix Lab were not touched. The wire
protocol is unchanged.

### What was implemented (F1–F3, smallest safe shapes)

**F2 — tombstoned deletion + teardown delivery guard**
- `handleAgentTunnelDelete` (`agent_topology.go`): keeps the record with
  the new `state=deleting` (tombstone) instead of removing it. The
  tombstone carries the two teardown revisions + `hub/node_teardown_ok`
  flags, and `agentTunnelNextInstance` therefore keeps the instance name
  reserved until both agents ack their remove desired (or the 24 h TTL
  drop). The remove desireds go out exactly as before, now revision-tracked.
- `agentHubDeliverDesired` (`agenthub.go`): refuses (typed error
  `agentErrPendingTeardown`) any delivery that would silently overwrite a
  pending, unacked remove — an apply, or a *different* instance's remove.
  Allowed supersessions: apply→apply (last-write-wins, S5 behavior kept),
  remove→apply (delete during a mid-flight provisioning), and a
  same-instance remove refresh.
- `handleAgentTunnelsPost`: refuses a create while either endpoint still
  holds a pending teardown (clear `E-AGENT-06` instead of a doomed record).
- `agentTunnelPowerRestart`: refuses power/restart on a tombstone.

**F1 — no orphans from delete-during-provisioning**
- `agentTunnelProvision` re-checks the record between stages:
  `agentTunnelStageGate` after the hub ack, and the atomic
  `agentTunnelBeginRegistering` before the node delivery. If the record
  was deleted (`deleting`) or powered off, the pipeline aborts — the
  delete flow already owns the teardown; if the record vanished entirely,
  a best-effort remove goes to both agents. A tombstone can therefore
  never receive, and never miss, the node bundle for a dead tunnel.
- `fail()` and `markState` never write onto a tombstone (no state
  resurrection), and the ack observer applies teardown acks only to
  tombstones and provisioning acks only to non-tombstones.

**F3 — startup reconciliation + ack-artifact preservation**
- The ack observer now persists `ack.Detail["main_host"]` on a successful
  hub ack, so the resume data survives a controller restart even when the
  provisioning goroutine that used to record it is gone.
- `reconcileAgentTunnels()` (called once from `wireAgentSubsystem`, i.e.
  once per controller start): re-runs incomplete `provisioning`/
  `registering` records and powered-on `error` records through the
  pipeline — with FRESH revisions, so agents refuse stale and treat equal
  revisions as no-ops, and every stage re-applies the *same* instance: a
  reconcile can never duplicate a service, port or firewall rule. The
  pipeline is resume-aware: a record whose hub ack + host file survived
  skips the hub stage entirely (no needless tinc restart). Deleting
  tombstones get exactly one teardown re-delivery with re-armed
  revisions; tombstones older than `agentTunnelTombstoneTTL` (24 h) are
  dropped and their instance name freed. There is deliberately **no retry
  timer** anywhere — reconcile is a one-shot scan.

### Test status

All audit pins that asserted a defect were FLIPPED to assert the repaired
behavior (S2 guard, S3 host preservation + reconcile offer, S4 no-orphan +
instance reservation); S1, S3-registering, S4-duplicate-ack and S5 kept
their (still-valid) pins. Five new `TestAgentRecoveryFix*` regression
tests cover the delivery-guard matrix, the hub-stage skip on resume, the
once-per-start reconcile semantics, the refused create, and the refused
power-on-tombstone. Full agent suite (incl. the e2e
`TestAgentTunnelControllerLoopRealHub` and the runtime tests) is green;
`gofmt`/`go vet` clean. The pre-existing Windows-host failures in
carrier/engine-switch tests were verified to fail identically on the
pristine `9984cff` baseline — unrelated to these changes.

### Remaining recovery limitations

1. A create refused over a pending offline teardown is retried by
   reconcile only at the next controller start; until then it needs a
   manual retry (bounded by design — no retry loop).
2. A tombstone whose agent never returns holds its instance name until
   the 24 h TTL drop at the next controller start.
3. An `error` record that fails provisioning again waits for the next
   controller start (one reconcile attempt per start) or a manual delete
   (now safe). Audit F4 (automatic hub-side rollback on node failure)
   remains unimplemented — MEDIUM, out of this round's scope.
4. Agent-side revision rejection (stale refused, equal = no-op) is
   documented in `docs/AGENT-CONTROLLER.md` and is load-bearing for the
   reconcile path; the runtime itself stays out of this audit's scope.
5. Audit F5 is only partially covered (deleting guard); power/restart on
   `provisioning`/`registering` records is still allowed.
