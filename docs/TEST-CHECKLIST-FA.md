# چک‌لیست تست کنترل‌شدهٔ دو سرور — اولین تونل Matrix با Agent

> این چک‌لیست برای اولین تست واقعی روی دو سرور آزمایشی اوبونتو (ایران + خارج) است.
> نسخهٔ کد: شاخهٔ `feature/agent-matrix-mvp` (فعلاً بدون ریلیز — بسته به یادداشت گام ۲).
> وضعیت امنیتی: طبق `docs/INTEGRATION-NOTES.md` جلسهٔ ۴، برای تست آزمایشگاهی **GO** با شرایط همین سند.

## ۰) پیش‌نیازها و هشدارها

- [ ] دو سرور اوبونتو ۲۴.۰۴ با دسترسی root و ساعت درست (NTP).
- [ ] کنترلر = سرور ایران (پنل Quantum نصب و فعال: `systemctl is-active gre-panel`).
- [ ] **قبل از هر تغییر:** از `/etc/gre-panel` بکاپ کامل بگیر (گام ۲). هیچ اسکریپتی `ufw reset` یا `iptables -F` اجرا نمی‌کند؛ اگر دیدی، متوقف شو.
- [ ] متغیر `GRE_PANEL_ALLOW_UNVERIFIED_UPDATE` روی هیچ سروری ست نباشد (پیش‌فرض fail-closed).
- [ ] اعتبارنامه‌ها فقط از طریق کلید SSH موقت محلی — هیچ رمزی در چت یا گیت نوشته نمی‌شود.

## ۱) موجودی‌گیری قبل از تست (روی هر دو سرور)

```bash
systemctl list-units --type=service --state=running | grep -Ei 'gre|xray|tinc|quantum|pasar|docker'
ss -tlpn | sort -k4            # فهرست پورت‌های TCP
ss -ulpn | sort -k4            # فهرست پورت‌های UDP
iptables-save > ~/iptables-before.txt; iptables-save | sha256sum
ip addr show; ip route show
df -h / ; free -m
```
- [ ] خروجی‌ها را ذخیره کن — در گام ۱۰ مقایسه می‌شوند.
- [ ] پورت‌های اشغال کنترلر را یادداشت کن: 7777 (HTTP پنل)، 7443 (TLS پنل)، 2097 یا پورت mesh موردانتظار Matrix، پورت‌های FRP/Backhaul در صورت وجود.

## ۲) بکاپ پنل و آماده‌سازی کنترلر

```bash
tar -czf ~/gre-panel-backup-$(date +%F).tgz /etc/gre-panel
```
- [ ] از `panel.json` بکاپ موجود است.
- [ ] چون v1.28.0 هنوز منتشر نشده، باینری کنترلر را از خروجی همین شاخه (built از `feature/agent-matrix-mvp`) با `--binary` نصب/به‌روزرسانی کن و `gre-panel version` = `v1.28.0` را تأیید کن.
- [ ] (اختیاری، مسیر nginx): نصب `install-controller.sh` هنوز **ناقص** است — فعلاً TLS خودِ پنل (7443) کافی است؛ Nginx بعداً.

## ۳) موجودی Matrix / PasarGuard / Xray موجود

- [ ] `/etc/gre-panel/matrix.json` وجود دارد؟ اگر یک Matrix قدیمی فعال است (`systemctl is-active quantum-matrix`)، یا نگهش دار یا قبل از تست حذفش کن — تداخل پورت mesh پیش می‌آید.
- [ ] PasarGuard Node و Xray **دست نمی‌خورند**؛ Agent فقط به‌صورت read-only تشخیص می‌دهد.
- [ ] پورت‌های forwards که می‌خواهی از تونل رد شود (۱ تا ۲۰ پورت، مثلاً 8443) روی سرور خارج آزاد باشند.

## ۴) نصب Agent (ترتیب: اول ایران، بعد خارج)

روی هر دو سرور (کلید SSH موقت، نه رمز):
```bash
scp gre-panel-linux-amd64 checksums.txt server:/tmp/
sudo bash install-agent.sh --server https://<IP-یا-دامنه-کنترلر>:7443/<base_path> \
     --binary /tmp/gre-panel-linux-amd64 --token-file /root/agent-token --yes
```
- [ ] ایران: نقش `iran` (توکن با نقش ایران ساخته شود)، خارج: نقش `foreign` — هر توکن فقط یک‌بار مصرف.
- [ ] بعد از نصب: `systemctl is-active gre-agent` و `gre-panel agent status` → `"connected": true`.
- [ ] `agent.json` باید `tls_pin` غیرخالی داشته باشد (شرط GO جلسهٔ ۴ — TLS اجباری، نه `http://`).
- [ ] هرگز `agent help` را با باینری مشکوک بدون سندباکس اجرا نکن — نصاب v5d168c3 خودش سندباکس می‌کند.

## ۵) ثبت (Enrollment) و ابطال (Revocation) در داشبورد

- [ ] تب «عوامل» کنترلر: دو Agent باید **online** با نقش و IP صحیح دیده شوند.
- [ ] تست ابطال: یکی از Agentها را revoke کن → در چند ثانیه session بسته می‌شود (`journalctl -u gre-agent` پیام revoked)؛ بعد دوباره با توکن تازه enroll کن.
- [ ] توکن مصرف‌شده دوباره استفاده نشود (401).

## ۶) ساخت یک تونل Matrix از داشبورد

- [ ] «ساخت تونل جدید»: Agent ایران = hub، Agent خارج = node، خانوادهٔ ipv4، پورت mesh = 0 (خودکار)، پورت forwards (حداقل یکی، نه 22).
- [ ] وضعیت باید provisioning → registering → **active** شود (_poll هر ۱۰ ثانیه_).
- [ ] عیب‌یابی: `journalctl -u gre-agent` روی هر دو سرور + `GET /api/agent-tunnels`.

## ۷) اثبات واقعی بودن تونل (نه فقط فعال بودن سرویس)

```bash
# روی ایران (hub): ping از داخل اینترفیس mesh
ping -I qmx0 10.254.231.2 -c 5
# روی خارج (node):
ping -I qmx0 10.254.231.1 -c 5
```
- [ ] کارت تونل: کیفیت (latency/jitter/loss) گزارش می‌شود؛ `systemctl is-active quantum-matrix` کافی نیست — ICMP داخل mesh باید جواب دهد.
- [ ] DNAT واقعی: از یک کلاینت به پورت forward روی IP ایران وصل شو → سرویس پشت node جواب دهد.

## ۸) بررسی ترافیک و آماری که نباید باورش کنی

- [ ] `GET /api/agent-tunnels` → فیلد `traffic`: نرخ rx/tx کارت شبکه و اینترفیس تونل.
- [ ] **`billable_amplification` فقط «برآورد در سطح سرور» است** — کل RX کارت شبکه ایران را می‌بیند (SSH/پنل/پروب هم داخلش است)؛ عدد مطلق Matrix نیست و اگر null بود یعنی «نامشخص».
- [ ] شمارش دقیق مالکیت‌شدهٔ Matrix (زنجیره‌های QMX) هنوز پیاده نشده — ادامهٔ کار.

## ۹) بقا در قطعی کنترلر و اتصال دوباره

```bash
# روی کنترلر:
systemctl stop gre-panel; sleep 120; systemctl start gre-panel
```
- [ ] در طول قطعی: تونل باید کار کند (ping بین دو سرور قطع نشود) — Matrix سرویس مستقل systemd است.
- [ ] Agentها باید با backoff وصل شوند و ظرف ~۲ دقیقه بعد از برگشت کنترلر دوباره online شوند.
- [ ] تست Agent-restart: `systemctl restart gre-agent` روی خارج → تونل قطع نشود، Agent دوباره وصل شود.

## ۱۰) حذف تونل و پاک‌سازی

- [ ] حذف تونل از داشبورد → هر دو سرور `matrixRemove` اجرا می‌کنند: unit، دایرکتوری tinc، زنجیره‌های QMX و state پاک می‌شود؛ `ip link` بدون qmx باقی می‌ماند؟ بررسی کن.
- [ ] حذف Agent: `sudo bash uninstall-agent.sh` (بدون purge: enrollment می‌ماند) / `--purge` (همه‌چیز).
- [ ] **پس از حذف:** `iptables-save | sha256sum` با گام ۱ مقایسه شود؛ قوانین QMX پاک شده باشند و هیچ قانون غیرMatrix‌ای تغییر نکرده باشد.

## ۱۱) مقایسهٔ نهایی بعد از تست

- [ ] `ss -tlpn` و `ss -ulpn` یکسان با گام ۱ (به‌جز تغییرات عمدی).
- [ ] `iptables-save` diff صفر روی قوانین غیرQMX.
- [ ] `systemctl list-units` بدون unit جدید/باقی‌مانده.
- [ ] PasarGuard/Xray/Docker دست‌نخورده (`docker ps` بدون تغییر).
- [ ] گزارش نتایج (موفق/ناموفق هر گام) ثبت شود.

## شرایط GO جلسهٔ ۴ که در همین چک‌لیست رعایت شد

1. فقط `https://` برای `--server` + تأیید `tls_pin`؛ ۲. توکن یک‌بارمصرف برای هر سرور + revoke هنگام re-enroll؛ ۳. `GRE_PANEL_ALLOW_UNVERIFIED_UPDATE` ست نشده؛ ۴. اجرای `go test -race` و `go test -count=5` روی CI لینوکس قبل از تست (طبق `docs/INTEGRATION-NOTES.md`).
