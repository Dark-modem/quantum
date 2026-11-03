# Network Optimization — Final Acceptance & Handoff (Session 2 → Session 3)

Date: 2026-11-03. Environment: disposable WSL2 Ubuntu 24.04.4 (live tests, root),
Ubuntu 26.04.1 (hermetic suite). No live lab servers touched; no releases; no main merge.

## 1. Base verification

- **main = `2ed6be3eb2083efdc7cfa972fb7f10df8e841e1a`** ("Fix the remaining Linux CI
  failures found by the security CI").
- **All five previously reported commits verified IN main:** `0ccb70d`, `d476593`,
  `21634f1`, `49fe166`, `bbb51a3` (merge-base --is-ancestor, all true). Netopt files
  (`netdetect.go`, `netprofile.go`, `netapply.go`, `netcli.go`, `netops_api.go`) present.

## 2. UI/protocol wiring by Session 3 — VERIFIED COMPLETE

- `panel/agentproto.go:91-96`: all six protocol ops (`netopt.detect/plan/apply/
  status/rollback/revert`); `agentValidCommands` includes them; `agentMutatingOps`
  gates `netopt.apply`, `netopt.rollback`, `netopt.revert` behind `confirm=yes`.
- `panel/agent_ops_dispatch.go`: all six ops route into the Session 2 engine
  (`NetopDetect/NetopPlan/NetopApply/NetopStatus/NetopRollback/NetopRevert`);
  the dispatcher additionally **requires a `justify` string for `netopt.apply`**
  (stronger than the CLI) and parses role/profile/reasons from the payload.
- `panel/app.js:8344+`: the ops UI posts to `/api/agents/{id}/op` with
  `{op, payload, confirm}` and renders JSON results — the six operations are
  wired. **No missing UI behavior found.**

## 3. Patches produced this round (branch `wt/s2-final-accept`, off main)

| Commit | Content |
|---|---|
| `bb0bbe7` | 2-core/2GB controller-compatible boundary acceptance test |
| `4a08ef6` | **Baseline-chain fix**: stacked applies overwrote the single baseline, so revert could not reach the true pre-netopt state. Every apply now appends an immutable `netopt/baselines/<ns>.json`; revert walks to the OLDEST. Stack regression test added (3 generations). |
| `6c63fb6`/… | (carry-over context; the report file this document sits beside) |

## 4. Acceptance cycle — agent-only live run (main binary, root, persistent dir)

Sequence `detect → plan → apply → status → rollback → revert` with `--json`:

| Check | Result |
|---|---|
| `no panel.json created` | PASS (asserted live + `TestNetopsAgentOnlyAllOpsNoFakePanel`) |
| persistent agent configDir (`/var/lib/...`, i.e. `<configDir>/netopt/`) | PASS |
| journal permissions | **0600** (stat: `600 journal.json`, `600 baseline.json`) |
| read-back correct | `verified=true` after apply |
| false drift after apply | **0** |
| real drift detected | manual somaxconn change → `drift:1 net.core.somaxconn` |
| rollback restores originals | all compared values restored (whitespace-normalized for vectors) |
| connectivity-loss guard | netns with no egress → `rolled_back=true, verified=false`, exit 1 |
| forbidden domains | UFW/SSHD/MTU **UNTOUCHED** (md5 before/after); iptables/nftables diffs proven **ambient** (churn with zero netopt action); no rp_filter/MSS/matrix-routing keys in any profile (structural test) |

## 5. Stacked-apply revert — the defect found and fixed this round

Live scenario: apply#1 (32768→8192) → drift to 555 → apply#2 (555→8192) → revert.
Before the fix, revert restored 8192-era values (single baseline = last apply).
After `4a08ef6`: **revert restored the true original 32768**, owned file removed,
chain cleaned. Regression test `TestNetopsStackedAppliesRevertToTrueOriginals`.

## 6. Low-resource acceptance (no performance claims — protocol in NETOPT-PERF.md)

- **1 vCPU / 956 MB Agent** (quantum-tuned somaxconn=65535): **Conservative**;
  exact apply set: `somaxconn 65535→4096`, `tcp_max_syn_backlog 65535→4096`,
  `tcp_mtu_probing 0→1`, `swappiness 60→10`. No buffers/conntrack/NIC/RPS offered.
- **2 vCPU / 2048 MB controller-compatible**: **Balanced** (not Conservative —
  2048 is not below the gate), buffers at the `ram>=2g` boundary (16 MB
  ceilings = ceilings, not allocations), conntrack 262144, Performance
  extras absent (2 cores < 4). Pinned by `TestAcceptTwoCoreTwoGBControllerCompatible`.

## 7. Test counts (at main + patches)

22 netopt-specific tests, all PASS: detection 2, profiles 3, plan/reserved-ports 2,
apply/rollback 2, agent-mode 6, dispatcher 2, acceptance/boundary 5.
Production build amd64 + arm64 cross-compile OK; `go vet ./...` clean.

## 8. Known cosmetic items (non-blocking, Session 3's discretion)

1. After `netopt revert`, the CLI still prints the last journal's applied list —
   harmless but potentially confusing; suggest suppressing after a successful revert.
2. `netopt apply` requires root — document in the installer docs (Session 6).
3. Kernel-26.04-specific behavior needs a real 26.04 kernel VM (WSL shares the
   6.6 kernel); ARM64 runtime needs ARM hardware/QEMU. Build-level coverage only.
