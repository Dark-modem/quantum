# Integration Notes — Matrix Agent MVP consolidation

Consolidation point of `feature/agent-matrix-mvp`. This file records what each
parallel session delivered, what is **open/unresolved**, and what the controlled
two-server test must respect. Nothing here claims a fix that has not landed.

## Session deliverables and their integration SHAs

| Session | Deliverable | Integration |
|---|---|---|
| 1 — recovery | `01d746f` F1/F2/F3 (tombstoned deletion, teardown guard, stage gates, startup reconciliation) | merged via merge of `wt/agent-recovery-fix`; audit trail in `docs/AGENT-RECOVERY-AUDIT.md`, regression tests in `panel/agent_recovery_audit_test.go` |
| 2 — scale/bench | `docs/AGENT-SCALE-BENCHMARK.md` + `panel/agent_scale_bench_test.go` + `tests/agent-scale/` (worktree `wt-agent-scale`, **uncommitted**) | findings recorded below; code NOT imported (test-only, not approved for production tree) |
| 3 — integration | this feature branch: protocol, runtime (A), hub/registry (B), orchestration, endpoint installer (6), Agents UI + error pages (D) | HEAD history: `c754106`…`564ad70` (see `git log main..feature/agent-matrix-mvp`) |
| 4 — security | `docs/AGENT-SECURITY-REVIEW.md` (draft, `wt-sec4`) and final verification `docs/AGENT-SECURITY-VERIFICATION.md` (draft, `wt-sec4-final` @ `134bde1`) | verdict recorded below; PoC file `panel/agentsec4_poc_test.go` NOT imported (uncommitted) |
| 5 — lab | `af1e7cca` in the standalone `panel-tunnel` repo | imported as `926695c` (authorship preserved): `tests/matrix-agent-lab/` + `docs/MATRIX-AGENT-LAB.md`; secrets/IP scan clean; `.gitattributes` not imported (the repo-wide `* text=auto eol=lf` rule already covers it) |
| 6 — installers | `825b241` endpoint installer + `5d168c3` gate-probe sandboxing | merged (`5265745`, `95e2f9b`); drift guards in `panel/agent_test.go` (`TestAgentInstallUnitMatchesInstaller`) |
| E — central installer | `install-controller.sh` draft | **INCOMPLETE — uncommitted** in worktree `wt-agent-e` (branch `wt/agent-e` @ `5c9c856`). Not integrated. The central controller currently relies on the panel's own TLS listener or a manually configured reverse proxy. |

## Session 2 — recorded findings (UNRESOLVED, by design)

From `AGENT-SCALE-BENCHMARK.md` (benchmarks measured, code not imported):

1. **Registry lost-update hazard (record as test-suite issue).** `saveAgentRegistry`
   requires the caller to hold `agentRegMu`. Every current call site was verified to
   hold it, but a single future caller without the lock would silently truncate the
   registry to a stale snapshot (classic lost update on load-modify-save). Session 2's
   recommended insurance — a lock-discipline comment on `agentRegistryUpdate`/
   `saveAgentRegistry` and/or a **`-race` CI run of the agent suite** — is NOT yet
   implemented. Race-detector result on this host: see below.
2. **Scale ceiling is real but out of MVP scope.** At the designed 30 s heartbeat the
   design is comfortable at the milestone (2 agents) and up to ~20 agents; ≥50 agents
   at stress cadence starve dashboard reads, and fsync-bound disks dominate. The
   documented optimization (in-memory registry + coalescing flusher) is explicitly
   deferred until >~20 agents or fsync >~5 ms.

## Session 4 — security verdict (recorded verbatim, NOT claimed fixed)

Status at integration point `134bde1` (verified by Session 4's runtime PoCs):
**1 of 11 findings fixed** — the CRITICAL F-11 (missing `agent` CLI dispatch).
**10 remain open — do not claim them fixed:**

| ID | Severity | Finding |
|---|---|---|
| F-1 | MEDIUM | `agentRevisionNewer` treats malformed revisions as "newer" (monotonicity degrades to inequality) |
| F-2 | MEDIUM | scheme-less `--server` silently becomes plaintext `ws://`; TLS is warn-only |
| F-3 | MEDIUM | agent WS read loop has no read deadline / ping-pong (silent dead peers linger) |
| F-4 | MEDIUM | `agentAPIError` local status table conflicts with the `E-AGENT-*` catalog (502/400 vs 504/403) |
| F-12 | MEDIUM | enrollment token transits process argv |
| F-13 | LOW | checksum manifest is unsigned, same-origin |
| F-14 | LOW | `uninstall --purge` deletes the shared binary on a single-unit-name heuristic |
| F-15 | LOW | local `--role` can disagree with the controller-minted role |
| F-16 | LOW | re-enrollment orphans the old controller identity (no revoke warning) |

**Session 4 verdict: GO** for the controlled two-server lab test under its conditions
(https:// URLs on both endpoints, `tls_pin` verified non-empty after enrollment,
one-time tokens per endpoint, revoke on re-enroll, `GRE_PANEL_ALLOW_UNVERIFIED_UPDATE`
unset) and **NO-GO for production exposure** until F-1..F-4 and F-12 (and F-13 before
any fleet rollout) close.

## Race detector (Session 2's request, run at consolidation)

`go test -race` on the agent controller suites — result recorded here:

**Not runnable on the consolidation host** (Windows, no C toolchain —
`go test -race` requires cgo/gcc, which is absent). The run MUST happen on
Linux CI before the two-server test:

```
go test -race -run 'TestAgent|TestErrorPages|TestAgents' ./panel/
```

Until that run is clean, Session 2's registry lost-update hazard stands as
an open test-suite issue (lock-discipline is enforced only by convention).

## Known test-suite issues (environment, not logic)

- 30 tests fail identically on `main` and on this branch on Windows hosts
  (Linux-only engine/health/stale-config labs: `TestSwitchEngine*`,
  `TestTunnelHealth*`, `TestStaleConfig*`, `TestFRP*Stress`, `TestPeerSwap*`,
  permission-mode assertions). Verified byte-identical failure sets against a
  pristine `main` worktree.
- The intermittent agent-test flake (instant 0.00 s failures) reported by Session 4
  was root-caused at consolidation: `freeUDPPort` selected UDP-only ports while
  Matrix's preflight probes TCP too, so a loaded host reused the same port's TCP
  side. Fixed in `564ad70` (`freeMeshPort`, dual-transport verification);
  8/8 consecutive combined runs green afterwards. Session 4's recommendation to
  re-verify on Linux CI (`go test -count=5 ./...`) stands.

## Deferred work (not started, tracked)

- Agent E's central installer (nginx + certbot webroot + WSS proxy) — draft only.
- Security batch F-1, F-2, F-3, F-4, F-12 (and F-13) before production exposure.
- Registry lock-discipline comment + `-race` in CI.
- Central-controller traffic ledger history (currently latest-heartbeat rates only).
