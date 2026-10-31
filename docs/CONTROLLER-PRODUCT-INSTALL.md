# Session 6 — Standalone Controller Installer + Real-Domain TLS: Delivery

**Branch:** `s6/controller-product` (own branch; `main` untouched; nothing published;
live lab servers and Session 3's operations untouched — all work is local commits).

## Delivered commits (exact, oldest first)

| Commit | Content |
|---|---|
| `31ad020` | installer-lib.sh: `fw_remove_port` (tag-scoped additive rollback), firewall-rule rollback on failed SSH bootstrap (SSH-3), anchored finalize Port keep (SSH-4), technical finalize guard over `$SSH_CONNECTION` (SSH-2); hermetic test `tests/test_controller_product.sh` |
| `8020a8e` | tools/QuantumSshKey.ps1: strict label validation + base64 pubkey transport (SSH-1) |
| `b673793` | install-agent.sh: pinned installer-lib download skeleton (SSH-5) |
| `bef0e27` | install-controller.sh: standalone product flow — Phase 0b binary+service install, tolerant preflight, strict A/AAAA DNS verification, port-80 challenge probe, extended TLS/WSS/SAN/renewal verification, wired `--verify-tls`, new flags |
| `2e8629b` | install-agent.sh: lib fetch pinned to `31ad020` + exact SHA-256 `565b9033f93a59f0c234bf06844319d8288807a74d2e953ca129a3a35379d807` |

Base: feature branch HEAD at branch time = `deaf2b3`.

## The 13-step controller flow as implemented

1. **Detect Ubuntu/arch** — `preflight_root_os` + `detect_arch` (amd64/arm64).
2. **Prerequisites** — `install_packages` (nginx, certbot, python3); curl/openssl ensured.
3. **Controller binary** — `install_controller_binary`: release tag via GitHub API
   (token-aware), per-arch asset download, **sha256 manifest fail-closed**, optional
   **Ed25519 `.sig` verification** with `--update-pubkey-file` (openssl), loud
   checksum-only warning otherwise, ELF + `version` + `agent help` gates
   (refuses pre-M2 binaries), atomic install.
4. **Isolated config/state/service** — `/etc/gre-panel` (0700), fresh admin password
   (root-only credentials file), `gre-panel.service` (Restart=always), loopback health
   check. Existing panel detected → kept (idempotent re-run/upgrade path).
5. **Loopback binding** — `panel.json bind_host=127.0.0.1` set at install time (fresh)
   and via the verified, auto-reverting switch (existing installs).
6. **Nginx reverse proxy** — site + WebSocket upgrade map + Persian RTL 50x page.
7. **HTTP → HTTPS** — 301 (or `--no-redirect`), verified.
8. **WSS forwarding** — dedicated `/api/agent/ws` location, Upgrade/Connection headers,
   3600 s timeouts; route verified post-install (101/403/400/302/401 pass,
   404/502/503/timeout fails).
9. **Let's Encrypt webroot** — ACME bootstrap vhost, `certbot certonly --webroot`,
   **port-80/challenge-path probe through the real domain before issuance**.
10. **Renewal + reload** — deploy hook (nginx reload), `certbot.timer` ensured,
    `certbot renew --dry-run` while nginx stays active, renewal config must read
    `authenticator = webroot`.
11. **Additive firewall** — tagged allow rules for 80/443 only.
12. **Verification** — HTTPS health through nginx, SAN carries the domain, issuer/expiry
    printed, redirect check, WSS route check (`--verify-tls` re-runs this phase alone).
13. **SSH bootstrap** — shared `ssh_bootstrap`, opt-in, non-fatal for the install.

`--domain <fqdn>` is the owner-provided name; the installer invents nothing: it
requires the **A record to equal this server's public IPv4**, **verifies every
published AAAA record against this server's own IPv6** before accepting it, probes the
challenge path over the real domain, and runs the renewal dry-run with nginx live.

## Session 4 fixes applied (all verified)

| Fix | Where | Evidence |
|---|---|---|
| SSH-5 unpinned `main` lib download | `install-agent.sh:44-73` | Pinned to commit `31ad020` + content SHA-256; **measured**: correct content accepted, one-byte tamper refused |
| SSH-1 label injection | `tools/QuantumSshKey.ps1` | **Measured**: 6 hostile labels rejected; hostile-comment pubkey round-trips twice, `NO-INJECTION`, exact line match |
| SSH-3 firewall residue | `installer-lib.sh` `ssh_bootstrap`/`fw_remove_port` | Hermetic test: tag-scoped removal only (untagged `-C` failure ⇒ no `-D`) |
| SSH-4 unanchored port keep | `installer-lib.sh` finalize | **Measured**: `Port 2222` kept, `Port 22221`/`Port 22`/`Port 2097` dropped |
| SSH-2 finalize guard | `installer-lib.sh` staged finalize | **Measured**: wrong-port SSH session refused (exit 3), new-port session passes, console passes, pubkey-only bootstrap skips the guard |
| Socket-activation migration/rollback | untouched | preserved verbatim (`ssh_apply`, finalize block) |

## Local test results (this machine, MEASURED)

- `bash -n` clean on all four installers.
- `tests/test_controller_product.sh` → **PASS** (14 assertions: finalize guard ×4,
  anchored keep ×3, password-auth line, ufw delete, iptables tag-scoped check+delete,
  no-delete-without-match, lib pin present, unpinned-`main` gone, PS1 label rule,
  base64 transport).
- PowerShell round-trip harness: label regex ×6 hostile inputs rejected; remote
  command executed twice in real bash with a hostile pubkey comment → rc 0/0,
  idempotent, no injection, exact content.
- Lib pin end-to-end: committed lib hashes to the pin (accepted); tampered copy
  refused.
- Full Go panel suite at the base commit: 905 PASS / 19 SKIP / 44 known-Windows-env
  FAIL (zero new-class) — installer changes are shell-only.

## VM test matrix (NOT executed here — run on disposable Ubuntu 24.04 VMs)

| # | Scenario | Command | Expected |
|---|---|---|---|
| V1 | Fresh install, clean VM | `sudo bash install-controller.sh --domain <owner-FQDN> --email <ops> -y` | Binary downloaded+verified, service active on loopback, nginx up, cert issued, dry-run renewal OK, all verification lines `[ok]`, summary printed |
| V2 | Re-run/idempotency | same command again | Binary kept, config kept ("existing config kept"), cert `--keep-until-expiring`, all `[ok]`, no duplicate rules/sites |
| V3 | `--check`-equivalent | `--dry-run` | Plan printed, zero mutations (verify with `ss`, `ls /etc/nginx`, `systemctl status`) |
| V4 | TLS re-verification | `--verify-tls` | SAN/renewal/WSS checks all `[ok]` without touching anything |
| V5 | Renewal dry-run under load | `certbot renew --dry-run` while dashboard open | succeeds, deploy hook reloads nginx, site stays up |
| V6 | Failed-issuance rollback | stop nginx / block port 80, run installer | challenge probe (or certbot) fails with a precise message; bootstrap vhost removed on validation failure; re-run succeeds after unblocking |
| V7 | DNS mismatch | A record → wrong IP | dies in preflight with the exact mismatch table; `--force-dns` prints the forced-warning and proceeds to a failing issuance (documented) |
| V8 | AAAA mismatch | AAAA → foreign IPv6 | dies unless `--force-dns` |
| V9 | Uninstall | `--uninstall` | proxy/TLS components removed, other nginx sites keep running, binary/service/config left unless confirmed |
| V10 | Upgrade | `--panel-version vX.Y.Z` on an installed host | binary swapped atomically, service restarted, config kept |
| V11 | Agent E2E | enroll an endpoint through `wss://<domain>/.../api/agent/ws` | agent online, commands flow through nginx |

Note: the domain itself is the owner's to provide — no FQDN was invented or used here;
every domain-dependent step is gated behind `--domain` and was validated by logic tests
and code review only.
