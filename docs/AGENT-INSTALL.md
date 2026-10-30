# Quantum Endpoint Agent — Installation and Removal

Installer and uninstaller for the lightweight Quantum endpoint Agent
(`gre-agent`) that runs on Iranian and foreign endpoints and keeps exactly one
outbound authenticated connection to the central Quantum Controller.

Endpoint scope: no web interface, no full Quantum panel, no PasarGuard Node
installation, no automatic PasarGuard updates, no nginx, no Docker, no
database, no monitoring stack. The agent installs nothing beyond the
`gre-panel` binary, its systemd unit and its identity files.

See also: [AGENT-CONTROLLER.md](AGENT-CONTROLLER.md) for the architecture and
the controller side (enrollment tokens, registry, WebSocket hub).

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [Installer options](#installer-options)
- [What the installer does](#what-the-installer-does)
- [Security model](#security-model)
- [Matrix independence](#matrix-independence)
- [Upgrades and rollback](#upgrades-and-rollback)
- [Uninstallation](#uninstallation)
- [Verification and health](#verification-and-health)
- [Files created](#files-created)
- [Testing matrix](#testing-matrix)
- [مستندات فارسی (Persian usage documentation)](#persian-usage-documentation)

## Quick start

On the controller, mint a one-time enrollment token with the endpoint role
(`iran` or `foreign`) — the role is baked into the token. On the endpoint:

Non-interactive (automation):

```bash
sudo GRE_GITHUB_TOKEN=ghp_xxx bash install-agent.sh \
  --server https://controller.example:7443/panel \
  --token-file /root/agent-token \
  --role foreign
```

Interactive (run without flags; prompts for the controller URL, the token
(hidden) and the role):

```bash
sudo bash install-agent.sh
```

Check-only (verifies prerequisites, downloads the release asset and its
SHA-256 manifest, changes nothing):

```bash
sudo GRE_GITHUB_TOKEN=ghp_xxx bash install-agent.sh \
  --server https://controller.example:7443/panel \
  --token-file /root/agent-token --check
```

Removal:

```bash
sudo bash uninstall-agent.sh          # keep identity + binary (no new token needed later)
sudo bash uninstall-agent.sh --purge  # remove everything agent-related
```

## Requirements

- OS: Ubuntu 24.04 or Ubuntu 26.04 (other systemd distributions work but are
  unsupported targets — the installer warns).
- Architectures: `amd64` (x86_64) and `arm64` (aarch64) — the release asset
  `gre-panel-linux-<arch>` is selected automatically.
- `root` (sudo). systemd running as PID 1.
- `curl` (installed automatically if missing) and `sha256sum` (coreutils).
- A one-time enrollment token minted on the controller (role `iran` or
  `foreign`).
- A GitHub read token for the private `Dark-modem/quantum` release
  repository, provided via `--github-token`, `GRE_GITHUB_TOKEN`/`GITHUB_TOKEN`
  or `/etc/gre-panel/github-token` (same conventions as `install.sh`).

The Agent runs as root by design: it manages the local `quantum-matrix*`
systemd units, tinc and xray on the controller's behalf. A dedicated non-root
user would break those operations, so the installer creates none.

## Installer options

| Option | Meaning |
| --- | --- |
| `--server URL` | Controller base URL, e.g. `https://controller.example:7443/panel` (required) |
| `--token TOKEN` | One-time enrollment token (or `--token-file`, or `GRE_AGENT_ENROLL_TOKEN`, or hidden prompt) |
| `--token-file FILE` | Read the token from FILE; fixed to mode 600 |
| `--role iran\|foreign` | Informational only, recorded locally; the authoritative role is the token's |
| `--name NAME` | Display name for the endpoint (default: hostname) |
| `--version latest\|vX.Y.Z` | Release to install (default `latest`) |
| `--github-token TOKEN` | GitHub read token for private release downloads |
| `--binary FILE` | Advanced/air-gapped: install a local binary (verified against `FILE.sha256` if present) |
| `--no-start` | Enroll and enable, but do not start the service |
| `--wait SECONDS` | Seconds to wait for the first controller connection (default 30) |
| `--force-enroll` | Re-enroll even if an identity already exists (use a fresh token) |
| `--check` | Verify prerequisites + download + SHA-256 only; change nothing |
| `--rollback` | Restore the previous binary and restart the agent |
| `--yes` | Never prompt (automation mode) |

Environment overrides (testing/mirrors): `QUANTUM_AGENT_RELEASE_BASE` points
the asset, manifest and `latest` resolution at an alternate base URL and
disables GitHub authentication for downloads;
`GRE_PANEL_ALLOW_UNVERIFIED_UPDATE=1` skips manifest enforcement (both follow
the ecosystem conventions in `update.go` / `install.sh`).

## What the installer does

1. Checks prerequisites: root, systemd, OS, architecture, `curl`.
2. Resolves the release tag (`latest` via the GitHub API or an explicit tag).
3. Downloads `gre-panel-linux-<arch>` and the `checksums.txt` manifest from
   the release and **verifies the SHA-256 (fail-closed)**, then sanity-checks
   that the binary is an ELF that runs, reports its version and actually
   implements the `gre-panel agent` subcommand (a binary without it falls
   through to the full panel startup — the installer refuses it).
4. Stops the running agent (upgrades only), backs up the previous binary to
   `/var/backups/quantum-agent/`, and installs the new one atomically at
   `/usr/local/bin/gre-panel`.
5. Enrolls with the controller via the runtime contract
   `gre-panel agent enroll --server <url> --token <token> [--name <name>]`
   and verifies `/etc/gre-panel/agent.json` exists with mode 0600.
6. Writes `/etc/systemd/system/gre-agent.service` — byte-identical to what
   `gre-panel agent install` produces — and runs
   `systemctl daemon-reload` + `systemctl enable --now gre-agent`.
7. Verifies the service is active, waits for the outbound WebSocket to the
   controller (`gre-panel agent status` → `ws.connected`), and asserts that
   no `quantum-matrix*` unit changed state during the install.

The systemd unit (created by the installer, identical to the runtime's own):

```ini
[Unit]
Description=Quantum Panel Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gre-panel agent run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

If the controller is unreachable at install time, enrollment fails cleanly
before the unit is created and the installer exits non-zero. If the controller
becomes unreachable after a successful install, the agent keeps retrying with
exponential backoff (2 s → 120 s, ±20 % jitter) — no operator action needed
beyond restoring the controller.

## Security model

- **One outbound connection.** The agent dials
  `<server>/<base_path>/api/agent/ws` with its agent ID/key headers. No
  inbound management listener exists; no firewall rule is added or removed.
  The installer never runs `ufw`, never rewrites SSH configuration and never
  touches Docker, nginx or PasarGuard.
- **Secrets.** The enrollment token and GitHub token are never printed,
  never logged and never written to disk by the installer. The GitHub token
  reaches curl via a stdin config file (not `ps`-visible), exactly as
  `install.sh` does. The runtime persists the agent key at
  `/etc/gre-panel/agent.json` (mode 0600, written by the binary itself) and
  pins the controller TLS certificate on first use (TOFU) — a changed
  certificate is a hard stop against MITM.
- **Token exposure note.** `agent enroll` accepts the token only as a CLI
  flag, so it is briefly visible in the process list to local root users
  while enrollment runs (a few seconds). Prefer `--token-file` or the hidden
  prompt over inline `--token` to keep tokens out of shell history.
- **Fingerprint.** The installer prints the verified SHA-256 of every binary
  it installs.

## Matrix independence

The local Matrix service stays independently managed by systemd:

- `gre-agent.service` declares no relationship (`After`, `Wants`, `BindsTo`,
  `PartOf`) with any `quantum-matrix*` unit.
- The agent never runs matrix power operations on its own behalf; matrix
  restart/stop/start arrive as allowlisted controller commands and target the
  `quantum-matrix*` units directly.
- Stopping, restarting, upgrading or uninstalling the agent never stops the
  Matrix tunnel. Both installers snapshot `quantum-matrix*` unit states and
  verify nothing changed.

## Upgrades and rollback

Upgrade (also the normal re-run path — fully idempotent):

```bash
sudo GRE_GITHUB_TOKEN=ghp_xxx bash install-agent.sh \
  --server https://controller.example:7443/panel --token-file /root/agent-token \
  --version v1.28.0
```

- The previous binary is rotated into `/var/backups/quantum-agent/`
  (`gre-panel.prev` + `gre-panel.prev.meta` with version and SHA-256).
- If a freshly installed binary fails to keep the service active, the
  installer automatically restores the previous binary and restarts.
- Manual rollback:

```bash
sudo bash install-agent.sh --rollback
```

Enrollment survives upgrades (the identity is untouched), and re-running the
installer with the same version swaps nothing when the installed binary's
SHA-256 already matches the release asset.

## Uninstallation

```bash
sudo bash uninstall-agent.sh          # stop, disable, remove the unit
sudo bash uninstall-agent.sh --purge  # + identity, state, metadata, backups, binary*
```

- Default keeps `/etc/gre-panel/agent.json` and the binary, so a later
  reinstall needs no new enrollment token.
- `--purge` removes the identity, `agent-state.json`, `/etc/gre-panel/agent/`,
  the backups and the binary — the binary only when no `gre-panel.service`
  (controller/panel) exists on the host.
- Uninstalling never touches `quantum-matrix*` units: tunnels keep running.
- To invalidate the endpoint's identity, revoke the agent in the controller
  UI; the endpoint has no CLI for that.

## Verification and health

```bash
systemctl status gre-agent
journalctl -u gre-agent -f
gre-panel agent status        # JSON: id, server, applied revision, ws.connected
```

`agent status` prints `ws.connected` from the run loop's journal; after a
fresh start it may take a few seconds to flip to `true`.

## Files created

| Path | Purpose | Mode |
| --- | --- | --- |
| `/usr/local/bin/gre-panel` | The agent binary (shared Quantum binary) | 0755 |
| `/etc/systemd/system/gre-agent.service` | The agent systemd unit | 0644 |
| `/etc/gre-panel/agent.json` | Enrollment identity (id, key, server, TLS pin) — written by the runtime | 0600 |
| `/etc/gre-panel/agent-state.json` | Desired-state journal + connection status — written by the runtime | 0600 |
| `/etc/gre-panel/agent/agent.env` | Installer metadata (server, role, version, SHA-256; no secrets) | 0600 |
| `/var/backups/quantum-agent/` | Previous binary for rollback | 0700 |

## Testing matrix

Validated against disposable VMs/containers only — never on production
servers. Required scenarios:

| Scenario | Expected behavior |
| --- | --- |
| Fresh install | Binary installed + verified, enrolled, unit enabled, WS connected, status shown |
| Repeated install | Idempotent: binary swap skipped when SHA matches, identity kept, service uninterrupted |
| Upgrade | New version active, previous binary rotated to backup, enrollment preserved |
| Rollback | `--rollback` restores the previous binary; automatic rollback when the new binary crash-loops |
| Uninstall | Unit removed, identity kept; `--purge` removes everything agent-owned |
| Reboot | `gre-agent` starts automatically (`WantedBy=multi-user.target`), reconnects to the controller |
| Controller unavailable at install | Enrollment fails, exit non-zero, no unit created, token still one-time-valid |
| Controller unavailable after install | Agent stays active, retries with backoff, reconnects automatically |
| Agent restart | `systemctl restart gre-agent` re-establishes the session |
| Matrix unaffected | `quantum-matrix*` unit states identical before/after every operation |
| Non-agent binary offered as a release | Refused by the `agent`-subcommand gate before anything is installed |

Latest run (disposable Ubuntu 24.04 VM with real systemd + mock controller,
and privileged Ubuntu 26.04 container): 75/76 checks passed on 24.04 (the one
failure was the test fixture's own startup race, not the installer), 12/12 on
26.04, plus a full VM-shutdown/reboot cycle with automatic reconnect.

---

<a id="persian-usage-documentation"></a>

## مستندات فارسی — نصب و حذف ایجنت Quantum

این سند نحوهٔ نصب، ارتقا، بازگردانی و حذف **ایجنت Quantum** روی سرورهای
نقطه‌انتها (داخل و خارج ایران) را توضیح می‌دهد. ایجنت یک اتصال خروجی احراز
هویت‌شده به کنترلر مرکزی برقرار می‌کند و **هیچ رابط وب، هیچ پنل کامل، هیچ
Nginx، Docker یا PasarGuard Node** روی سرور نصب نمی‌شود.

### پیش‌نیازها

- سیستم‌عامل: Ubuntu 24.04 یا Ubuntu 26.04
- معماری: `amd64` یا `arm64`
- دسترسی روت (sudo) و systemd فعال
- یک توکن یک‌بار‌مصرف Enroll که از کنترلر گرفته‌اید (نقش `iran` یا `foreign`
  داخل توکن ثبت می‌شود)
- توکن خواندن GitHub برای دانلود ریلیزهای خصوصی (یا فایل
  `/etc/gre-panel/github-token`)

### نصب سریع

حالت غیرتعاملی (مناسب اتوماسیون):

```bash
sudo GRE_GITHUB_TOKEN=ghp_xxx bash install-agent.sh \
  --server https://controller.example:7443/panel \
  --token-file /root/agent-token \
  --role foreign
```

حالت تعاملی (بدون پارامتر اجرا کنید؛ آدرس کنترلر، توکن — مخفی — و نقش را
می‌پرسد):

```bash
sudo bash install-agent.sh
```

فقط بررسی و دانلود، بدون هیچ تغییری:

```bash
sudo GRE_GITHUB_TOKEN=ghp_xxx bash install-agent.sh \
  --server https://controller.example:7443/panel \
  --token-file /root/agent-token --check
```

### ارتقا و بازگردانی

```bash
# ارتقا به نسخهٔ مشخص (هویت ایجنت حفظ می‌شود)
sudo GRE_GITHUB_TOKEN=ghp_xxx bash install-agent.sh \
  --server https://controller.example:7443/panel \
  --token-file /root/agent-token --version v1.28.0

# بازگردانی دستی به باینری قبلی
sudo bash install-agent.sh --rollback
```

اگر بعد از ارتقا سرویس فعال نشود، نصاب به‌صورت خودکار باینری قبلی را برمی‌گرداند.

### حذف

```bash
sudo bash uninstall-agent.sh          # سرویس حذف می‌شود؛ هویت و باینری می‌مانند
sudo bash uninstall-agent.sh --purge  # حذف کامل همهٔ فایل‌های مربوط به ایجنت
```

توجه: حذف ایجنت هرگز سرویس‌های `quantum-matrix` (تونل‌های Matrix) را متوقف
نمی‌کند. برای باطل‌کردن هویت این سرور، ایجنت را از پنل کنترلر حذف (Revoke)
کنید.

### بررسی وضعیت

```bash
systemctl status gre-agent
journalctl -u gre-agent -f
gre-panel agent status
```

### نکات امنیتی

- توکن Enroll و توکن GitHub هرگز چاپ یا ذخیره نمی‌شوند؛ توصیه می‌شود به‌جای
  `--token` از `--token-file` یا حالت تعاملی استفاده کنید تا توکن وارد تاریخچهٔ
  شل نشود.
- `/etc/gre-panel/agent.json` با سطح دسترسی 0600 نگه‌داری می‌شود و کلید ایجنت
  هرگز نمایش داده نمی‌شود.
- ایجنت فقط اتصال خروجی دارد؛ هیچ پورت ورودی باز نمی‌شود و فایروال دست‌نخورده
  می‌ماند. `ufw reset` هرگز اجرا نمی‌شود و پورت SSH شما تغییر نمی‌کند.
- گواهی TLS کنترلر بار اول (TOFU) ثبت می‌شود؛ اگر گواهی کنترلر تغییر کند،
  ایجنت برای جلوگیری از حملهٔ میانی اتصال را رد می‌کند.
