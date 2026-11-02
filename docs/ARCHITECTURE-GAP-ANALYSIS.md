# Architecture & Implementation Gap Analysis — Quantum Controller/Agent Product

**Session 3 · 2026-10-31 · branch `feature/agent-matrix-mvp` @ `9c241a7`** (verified;
`f9bfb3d` + the imported installer draft). Supersedes the two-server deployment plan's
assumptions: the existing experimental servers are **disposable test machines only**;
the production Controller is a future dedicated Iranian server installed with
`install-controller.sh`; every tunnel endpoint gets only `install-agent.sh`.

## خلاصهٔ مدیریتی (فارسی)

محصول نهایی دو نقش دارد: **کنترلر مرکزی** (سرور جدید و قدرتمند در ایران؛ پنل گرافیکی کامل + هاب WebSocket + مدیریت Agentها + به‌روزرسانی خودش از پنل) و **Agent سبک** (فقط روی سرورهای تونل؛ بدون پنل و بدون listener عمومی؛ اتصال خروجی WSS). دو نصب‌کنندهٔ اصلی محصول عبارت‌اند از `install-controller.sh` و `install-agent.sh`.

چیزی که **الان هست:** هستهٔ کامل Agent/کنترلر (پروتکل، ثبت‌نام، desired-state، تونل Matrix تا وضعیت active، رابط «عوامل» در داشبورد، صفحات خطا)، `install-agent.sh` باکیفیت، پیش‌نویس `install-controller.sh`.

چیزی که **گم است:** نصب کامل کنترلر از صفر توسط نصب‌کننده، به‌روزرسانی Agent از پنل با امضای رمزنگاشتی، گزارش CPU/RAM/دیسک از سمت Agent، مدیریت SSH/فایروال خودکار در نصب‌کنندهٔ endpoint، ماژول بهینه‌سازی شبکه، و sub-بخش‌های backup/restore/reconfigure در نصب‌کنندهٔ مرکزی. سرورهای آزمایشی فعلی فقط برای تست مخرباند و هیچ‌کدام کنترلر تولیدی نخواهند بود.

---

## 1. Final architecture

```
production (later):  new dedicated Iran server          N tunnel endpoints (Iran/foreign)
                     ┌─────────────────────────────┐
   browser ─ HTTPS ─▶│  Controller                  │        ┌──────────────┐
                     │  · Quantum web panel (UI)    │◀─WSS──▶│ Agent (only) │ ×N
                     │  · agent hub + registry      │        │ gre-agent    │
                     │  · tunnel orchestration      │        │ matrix/tinc  │
                     │  · update mgmt (self+agents) │        └──────────────┘
                     │  · nginx :80/:443 + LE       │
                     └─────────────────────────────┘
install-controller.sh                        install-agent.sh

lab (now): disposable test hosts — a fresh test Controller instance may share
one disposable host with an Agent explicitly as a LAB-ONLY arrangement.
```

Trust boundaries: Controller holds registry + tokens (0600); agents hold their own
identity + TOFU pin; commands are allowlist-only; agent updates must verify
**signatures** (not same-origin checksums); SSH private keys never leave the
operator's machine.

## 2. Already implemented (verified on this branch)

| Area | Delivered | Where |
|---|---|---|
| Agent runtime | `agent enroll/run/install/uninstall/status`; outbound WSS + hello/welcome + heartbeats + TOFU SPKI pinning; reconnect 2s→120s ±20%; identity + desired-state journal on disk; offline reconciliation | `panel/agent*.go` |
| Agent Matrix ops | hub/node provisioning reusing the proven tinc path; revision rules (stale rejected, equal idempotent); allowlist commands `matrix.start/stop/restart/register`, `diag.ping` (IP-validated); no shell surface | `agent_matrix_local.go` |
| Controller hub | registry + single-use hashed enrollment tokens; WS hub (newest session wins); desired/ack; command round-trips; traffic-rate derivation; revocation with kick; `E-AGENT-01..06` | `agentreg.go`, `agenthub.go` |
| Tunnel mgmt (Matrix) | create→hub desired→hosts/main harvest→node bundle→register relay→active; power/restart/delete; multi-instance per hub (`matrix`…`matrix8`); health from mesh pings; server-wide traffic estimate (`basis:"server"`) | `agent_topology.go` |
| Recovery | tombstoned deletion, teardown guard, stage gates, controller-restart reconciliation | `01d746f`, `docs/AGENT-RECOVERY-AUDIT.md` |
| UI | Agents tab (tokens, agents, tunnels, commands), branded Persian error pages (14 codes), i18n | `app.js`, `errorpages.go` |
| Controller self-update | **already exists from before the agent work**: channels, checksums.txt verification, atomic swap, pending/rollback journal (`panel/update.go`, `update_guard.go`, `/api/update*`) | pre-existing |
| Endpoint installer | download+checksum fail-closed, ELF/agent-subcommand gates (sandboxed probe), enroll, unit, verification incl. controller WS + Matrix-untouched snapshot, upgrade rotation + auto/manual rollback, idempotent re-run, `--purge` | `install-agent.sh`, `uninstall-agent.sh` |
| Central installer | draft: DNS validation, nginx + WSS route, certbot webroot + deploy hook + `--verify-tls`, additive firewall, `bind_host`, dry-run, backup/rollback, uninstall | `install-controller.sh` (draft, `9c241a7`) |
| Tests | ~120 new Go tests incl. real-hub e2e; drift guards; recovery pins; lab (imported) | `panel/*_test.go`, `tests/matrix-agent-lab/` |

## 3. Missing functionality (the gap)

**G1 — Controller bootstrap in `install-controller.sh`** (largest installer gap): the
draft assumes a pre-installed panel. Needs: system detection (Ubuntu version/arch/
RAM/disk/virtualization via systemd-detect-virt), controller binary download+verify,
`gre-panel.service` setup, admin bootstrap, then the existing nginx/TLS phases.

**G2 — Agent update from the Controller UI (major):** protocol desired-type
`agent.update {version, sha256, signature, url}`; agent-side download→verify→atomic
swap→detached self-restart→reconnect→version report→auto-rollback on crash-loop
(prev binary kept); Controller UI: channel + version pick, progress from state
reports, rollback status. Preserves identity + tunnel desired state (already on disk).

**G3 — Agent resource reporting:** CPU/RAM/disk/arch/uptime/load + listening ports
(`/proc`, statfs, `ss -tulnp` parsed) → state report → registry → UI. Also enables
port-ownership views (C).

**G4 — SSH + firewall automation in `install-agent.sh`:** dedicated admin user +
sudo (whitelisted or full), key provisioning (public key via operator; private key
never leaves the operator), SSH port change **verified before** disabling old access
(new port tested from outside, then old port closed last), firewall rules additive +
Quantum-owned chains only, plan/dry-run + before/after snapshots, recovery path.

**G5 — Firewall/port management domain (C):** controller-side inventory from agent
reports (listening ports + ownership hints), Quantum-owned chains (`QUANTUM-*`),
plan/apply/revert with snapshots + audit trail; collision detection vs matrix
reserved ports (exists locally) extended to the declared mapping.

**G6 — Network optimization (D):** profiles conservative/balanced/performance as
desired-state (`network.optimize`), support checks (BBR availability, NIC, virt),
reversible sysctl/CC/queue/MTU via one Quantum-owned sysctl file per profile,
health-gated auto-rollback (health window already exists), per-node choice; measured
baseline vs after (throughput test must stay manual/on-demand — owner priority 5).

**G7 — Signed artifacts (updates trust):** CI signs every release artifact (minisign
or ed25519 detachec sig); Controller verifies Controller updates against a pinned
public key; agent updates verify the same way; checksums remain as belt-and-braces.
(Replaces the same-origin-checksum-only trust — Session 4 F-13 class.)

**G8 — Central installer polish:** backup/restore/reconfigure subcommands, Persian-
readable log mode, `renew --dry-run` promoted from non-fatal to a gated `--verify-tls`
run during install, agent-version management hooks (G2 server side).

**G9 — Diagnostics depth:** p95 latency in the health window (samples already
collected), throughput measurement kept strictly on-demand (owner priority 5: Iranian
billable RX), measured-vs-estimated labeling everywhere (already the convention).

## 4. `install-agent.sh` quality & required changes

Quality: good — 796 lines, fail-closed checksum, sandboxed gate, unit byte-identity
with the runtime, upgrade rotation + auto-rollback, Matrix-untouched verification,
idempotent. Required: G4 (SSH/admin/firewall/profile modules), resource minimums
(RAM/disk/virt detection), conflicting-service detection breadth, Persian log mode,
and reading the update-relevant metadata (G2) so reinstall/upgrade preserves
enrollment (already does).

## 5. `install-controller.sh` draft quality & required changes

Quality: solid foundations (see §8 draft above) — 957 lines, phased, verified.
Required: G1 bootstrap (the main work), G8 subcommands, G7 signature verification
for the controller artifact it downloads, Persian log mode, and wiring the agent-hub
URLs into the printed summary.

## 6. Firewall & SSH automation design (G4/G5)

- Detection: `nft list ruleset` non-empty → nftables is authoritative; else ufw
  active → ufw; else raw iptables. Quantum never mixes layers.
- Quantum-owned chains only: `QUANTUM-IN`/`QUANTUM-OUT` (filter) + per-purpose
  chains (`QMX*` exists for Matrix); jumps inserted idempotently with `-C || -I`;
  never `-F` on system chains; `ufw reset` forbidden.
- Plan/dry-run: every mutation has a `--plan` mode printing before/after; snapshots
  (`iptables-save` + nft dump + hashes) under `/var/backups/quantum-*`; one-command
  revert.
- SSH: create `qadmin` (sudo), install operator's public key, `sshd_config.d/
  quantum-port.conf` for a custom port, **verify new access live (outside the old
  session, new port, key-only) before** disabling password/root access; old access
  disabled last with a countdown + revert file. Recovery: a root-owned
  `/usr/local/sbin/quantum-ssh-revert` that restores the previous sshd config.

## 7. Network optimization design (G6)

Per-node desired-state: `{profile: conservative|balanced|performance}` → agent
checks support (BBR module, qdisc, virt flags), writes ONE file
`/etc/sysctl.d/97-quantum-<profile>.conf`, applies, records a revert snapshot, and
runs the existing 60s health window: if loss/latency deteriorate beyond thresholds
for 3 consecutive windows → auto-revert + report. Baseline capture: current health
window + optional on-demand throughput probe (manual trigger only). MTU changes only
on the tunnel interface (qmx MTU already managed by Matrix).

## 8. Update architecture (G2/G3/G7)

- **Controller self-update:** existing (`update.go`) — add signature verification
  (G7) to the existing checksum check; UI already shows progress/rollback.
- **Agent update:** new desired type `agent.update` (op, not shell): the Controller
  UI picks channel+version → Controller resolves the release manifest **itself**
  (download + verify signature server-side) → sends `{url, sha256, signature,
  version}` in desired state → agent downloads (never executes Controller-supplied
  commands — the artifact is a signed binary), verifies, swaps atomically
  (`gre-panel.new` → rename, ETXTBSY-safe stop of gre-agent first),
  schedules a detached self-restart (`systemd-run` or `at`-less: write a
  `oneshot` helper unit), reconnects with the SAME identity (on disk), reports
  `version` in hello; Controller marks success when the new version appears.
  Rollback: agent keeps `gre-panel.prev`; if NRestarts ≥ 3 within 5 min of an
  update → restore prev + report `update_failed` state. Identity + desired state
  live in `/etc/gre-panel/agent*.json` — untouched by swaps.
- Release channels: reuse the panel's channel concept (`stable`/`dev`) for agents;
  Controller stores per-agent channel in the registry.

## 9. Safe migration from current implementation

1. The feature branch keeps evolving; the experimental servers get builds from it
   (`--binary`), not releases.
2. The existing Iran panel is **not** migrated to production — it is test
   infrastructure; its data stays disposable.
3. `install-agent.sh` remains backward compatible: enrolled hosts upgrade via
   re-run (identity preserved) or the new G2 update path once it lands.
4. `install-controller.sh` gains G1 without breaking its existing phases (idempotent
   phases; preflight accepts both "panel present" and "fresh server" paths).
5. Protocol changes (agent.update, resources) bump `agentProtoVersion` only if wire-
   incompatible; additive fields keep v1.

## 10. Ordered implementation milestones

| # | Milestone | Contents | Size |
|---|---|---|---|
| M1 | Agent resource + port reporting | G3 (state report + registry + UI + tests) | small — **starting now** |
| M2 | Agent updates (G2+G7) | protocol + agent swap/rollback + Controller UI + signed CI artifacts | large |
| M3 | Controller installer bootstrap (G1) | fresh-server path + detection + Persian logs | medium |
| M4 | SSH/firewall automation (G4) | agent installer modules + revert tooling | medium |
| M5 | Firewall/port domain (G5) | inventory, ownership, plan/apply/revert + audit | medium |
| M6 | Network optimization (G6) | profiles + health-gated revert + UI | medium |
| M7 | Diagnostics depth (G9) + installer polish (G8) | p95, subcommands | small |
| M8 | Signed releases end-to-end (G7 CI) | minisign in workflow + verification | small after M2 |

Each milestone lands as small commits with tests on this branch; no new branch, no
release, no version bump beyond the existing unreleased v1.28.0 marker.
