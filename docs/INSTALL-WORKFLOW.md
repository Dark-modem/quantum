# Quantum Installation & SSH Bootstrap Workflow

The owner-facing installation experience for both Quantum roles, with
automated SSH administrative-access provisioning. Persian guide below
(راهنمای فارسی در ادامه).

Roles and entrypoints:

| Role | Entrypoint | Nginx | Firewall |
| --- | --- | --- | --- |
| Central Controller | `install-controller.sh` | Yes (HTTPS + WSS reverse proxy, Let's Encrypt) | additive tagged rules (80/443 + SSH) |
| Endpoint Agent | `install-agent.sh` | No (optional later, never silent) | additive tagged rules (SSH only) |

Shared helpers: `installer-lib.sh` (sits next to both installers; standalone
copies fetch it automatically). PowerShell client: `tools/QuantumSshKey.ps1`.

## The owner's sequence (enforced by the installers)

1. Install the Quantum Controller or Agent (binary, enrollment, systemd unit).
2. Verify its service starts (agent: `ws.connected`; controller: panel health through nginx).
3. Prepare the SSH administrative account (`qadmin` by default — key-only, sudo).
4. Install the new SSH **public** key (idempotent append; private key never leaves the workstation).
5. Configure the requested SSH port (**added**, never replacing the current one).
6. Add the SSH allowance to the firewall manager (additive, tagged `quantum:<role>:ssh-alt`, rate-limited).
7. Validate `sshd` configuration (`sshd -t`; on failure the quantum drop-in is rolled back).
8. Reload SSH safely (`systemctl reload ssh`; existing sessions never dropped).
9. Test access through the new port and key (client-side: `Test-QuantumSsh`).
10. Only after a successful test, optionally disable the old port/password (`Complete-QuantumSsh`).
11. The exact SSH command and key file path are printed by both installers and `Show-QuantumSshCommand`.

**Never lockout rule:** steps 3–8 are additive. The old SSH port and password
login stay fully enabled until step 10 succeeds *through the new access*.

## Workflow

On the Windows workstation:

```powershell
cd tools
.\QuantumSshKey.ps1 New-QuantumSshKey -Label endpoint-1          # generates %HOME%\.quantum\ssh\endpoint-1_ed25519(.pub)
```

On the server (copy `install-agent.sh` + `installer-lib.sh`, or use the one-liner):

```bash
sudo bash install-agent.sh --server https://controller.example:7443/panel \
  --token-file /root/agent-token --role foreign \
  --ssh-pubkey-file /root/endpoint-1_ed25519.pub --ssh-port 2222 --yes
```

Back on the workstation:

```powershell
.\QuantumSshKey.ps1 Test-QuantumSsh     -Label endpoint-1 -HostName <server> -User qadmin -Port 2222
# only if the test passed and you want to lock the old door:
.\QuantumSshKey.ps1 Complete-QuantumSsh -Label endpoint-1 -HostName <server> -User qadmin -Port 2222
.\QuantumSshKey.ps1 Show-QuantumSshCommand -Label endpoint-1 -HostName <server> -User qadmin -Port 2222
```

### Exact connection command format

```
ssh -i %USERPROFILE%\.quantum\ssh\<label>_ed25519 -p <ssh-port> <ssh-user>@<server-address>
```

Example: `ssh -i C:\Users\me\.quantum\ssh\endpoint-1_ed25519 -p 2222 qadmin@203.0.113.10`

## Interfaces for other sessions

- **Firewall engine (Session 1):** `fw_available`, `fw_has_rule`, `fw_allow_port <role> <name> <port> <proto> [limit]` in
  `installer-lib.sh` — additive, ownership-tagged (`quantum:<role>:<name>`), never resets/flushes/disables, never enables
  the firewall (enforcement stays with the engine). Replace the ufw backend by defining these before sourcing.
- **Network optimization engine (Session 2):** `netopt_prepare_server <role>` — stable call site in both installers;
  sysctl/tuning is fully delegated; this installer touches no kernel parameters.
- **Runtime (Session 3):** untouched; installers only drive the documented CLI (`gre-panel agent …`) and release assets.

## Guarantees

- Private keys: generated locally, ACL-restricted (`%USERPROFILE%\.quantum\ssh`), never in Git, state, logs or the server.
- Repeated runs: no duplicate users, keys or firewall rules (all idempotent).
- Agent uninstall never touches Matrix services; controller uninstall removes only its own nginx/TLS artifacts.
- Supported: Ubuntu 24.04 / 26.04, amd64 / arm64.

---

## راهنمای فارسی — نصب و راه‌اندازی SSH

این گردش‌کار، نصب کنترلر یا ایجنت کوانتوم را با آماده‌سازی خودکار دسترسی مدیریتی SSH کامل می‌کند.

ترتیب کار (نصاب‌ها همین ترتیب را اجرا می‌کنند):

1. نصب کنترلر یا ایجنت (باینری، enrollment، سرویس systemd)
2. بررسی صحت راه‌اندازی سرویس
3. ساخت حساب مدیریتی SSH (پیش‌فرض `qadmin` — فقط با کلید، دارای sudo)
4. نصب **کلید عمومی** جدید (کلید خصوصی هرگز از کامپیوتر شما خارج نمی‌شود)
5. افزودن پورت SSH درخواستی (**پورت قبلی حفظ می‌شود**)
6. افزودن قانون فایروال (فقط افزودنی، با برچسب مالکیت، با محدودیت نرخ)
7. اعتبارسنجی پیکربندی sshd (در صورت خطا، تغییرات کوانتوم برمی‌گردد)
8. بارگذاری مجدد امن sshd (نشست فعلی شما قطع نمی‌شود)
9. تست دسترسی جدید از ویندوز (`Test-QuantumSsh`)
10. فقط بعد از تست موفق — و به اختیار شما — بستن در قدیم (`Complete-QuantumSsh`)
11. ارائهٔ دستور دقیق SSH و مسیر کلید

فرمان دقیق اتصال:

```
ssh -i %USERPROFILE%\.quantum\ssh\<label>_ed25519 -p <ssh-port> <ssh-user>@<server-address>
```

نکات امنیتی:

- کلید خصوصی در `%USERPROFILE%\.quantum\ssh` با ACL محدود ذخیره می‌شود؛ هرگز آن را در گیت، لاگ یا سرور ذخیره نکنید.
- تا وقتی مرحلهٔ ۱۰ را اجرا نکرده‌اید، پورت قبلی و ورود با رمز فعال می‌مانند — همیشه راه بازگشت دارید.
- نصب تکراری کاربر، کلید یا قانون فایروال تکراری نمی‌سازد.
- حذف ایجنت، سرویس‌های Matrix را حذف نمی‌کند.

باگ مربوط به موتور فایروال (نشست ۱) و موتور بهینه‌سازی شبکه (نشست ۲) از طریق توابع `fw_*` و `netopt_prepare_server` در `installer-lib.sh` انجام می‌شود؛ این نصاب‌ها هرگز مستقیماً آن موتورها را تغییر نمی‌دهند.
