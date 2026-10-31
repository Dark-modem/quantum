# گزارش پذیرش لینوکس — زیرسیستم Network Optimization (نشست ۲)

**کُمیتی که تست شد:** `b4a40693a8fd139180d9f769aa5cf2bebaa1e76a` روی شاخه `wt/session2-netopt`
(تست‌های پذیرش و دو اصلاح حاصل از همین rounds تا `0ccb70d` روی همان شاخه اضافه شدند — پایین را ببینید).
**هیچ سرور lab زنده‌ای لمس نشد؛ هیچ پروفایلی روی سرور واقعی اعمال نشد؛ هیچ push/merge انجام نشد.**

---

## ۱. محیط‌های تست

| محیط | وضعیت | محدودیت |
|---|---|---|
| Ubuntu 24.04.4 LTS (WSL2 distro، یک‌بارمصرف) | تست کامل live | کرنل مشترک WSL: `6.6.87.2-microsoft-standard-WSL2` |
| Ubuntu 26.04.1 LTS (WSL2 distro، نصب یک‌بارمصرف از `wsl --install Ubuntu-26.04`) | تست hermetic + detect/plan فقط‌خواندنی | همان کرنل WSL — تفاوت کرنلی 26.04 (کرنل ~7.0) قابل تست نبود |
| ARM64 | کراس‌کامپایل موفق (`CGO_ENABLED=0 GOOS=linux GOARCH=arm64` → ELF aarch64) | اجرای runtime موجود نبود (QEMU-aarch64 نصب نیست؛ میزبان x86_64 است) |
| KVM | `/dev/kvm` موجود | استفاده نشد — WSL distro ها برای این پذیرش کافی بودند |

## ۲. دقت Hardware Detection (Ubuntu 24.04، واقعی)

دستور: `gre-panel netopt detect` و مقایسهٔ خروجی با خواندن مستقیم `/proc` و `/sys`:

```
PASS kernel | PASS cc_live | PASS somaxconn_live | PASS swappiness_live
PASS primary_eth0 | PASS mtu_live | PASS cores_ge1      ← 7/7 PASS
```

مقادیر اندازه‌گیری‌شده روی میزبان تست: kernel `6.6.87.2-WSL2`، virt `wsl`، 16 هسته، 7788 MB RAM
(91٪ آزاد)، `cc=bbr` (موجود: reno/cubic/bbr)، qdisc `fq`، primary `eth0`.

## ۳. انتخاب پروفایل

- میزبان تست (7788 MB، مجازی): **Balanced** با دلایل ثبت‌شده: «RAM 7788 MB < 8 GB»،
  «virtualized NIC/host shaping: Performance extras limited».
- **میزبان کم‌منظورهٔ شبیه ایران (1 vCPU / 956 MB)** — با fixture سینتتیک (تست
  `TestAcceptIranLikeServerSelectsConservative`): انتخاب **Conservative**. مجموعهٔ دقیق تغییرات:
  ```
  net.core.somaxconn            65535 -> 4096   (همگرایی رو به پایین از حالت tuned شدهٔ quantum.sh)
  net.ipv4.tcp_max_syn_backlog  65535 -> 4096
  net.ipv4.tcp_mtu_probing      0 -> 1
  vm.swappiness                 60 -> 10
  ```
  و هیچ پیشنهاد buffer/conntrack/NIC/RPS برای این سرور تولید نمی‌شود (تست می‌کند).
- شکاف‌های detection (cpuinfo/uname نخواندنی) ← اجباراً **Conservative** با warning ثبت‌شده.

## ۴. Apply واقعی، Read-back، Drift، Rollback (24.04، به‌عنوان root)

دستورات: `GRE_PANEL_DIR=… gre-panel netopt apply` سپس `status` و `rollback`.

- **Apply اول (قبل از کشف باگ):** ۳ تنظیم اعمال شد (`somaxconn 9999→8192`، tcp_rmem/tcp_wmem —
  دومی فقط تفاوت tab/space بود)، فایل owned `/etc/sysctl.d/99-quantum-netopt.conf` درست نوشته شد،
  journal+baseline ذخیره شد، `verified=true`، اتصال بعد از apply سالم (curl code=200).
- **Drift: کار می‌کند.** تغییر دستی somaxconn به 9999 → `status` گزارش `DRIFTED` داد؛
  برگرداندن مقدار → `ok`.
- **باگ واقعی شمارهٔ ۱ (کشف‌شده در همین پذیرش):** rollback شکست خورد —
  `restore net.core.somaxconn: exit status 1`. علت: `netRestore` مقدار را با کوتیشن
  (`key="8192"`) به `sysctl -w` می‌داد؛ چون از exec (بدون shell) استفاده می‌شود، کوتیشن‌ها
  لیترال می‌رسیدند و sysctl رد می‌کرد. **اصلاح شد** (کامیت `0ccb70d`).
- **باگ واقعی شمارهٔ ۲:** مقایسهٔ no-op رشته‌ای بود؛ کرنل بردارها را با tab چاپ می‌کند و
  پروفایل با فاصله می‌نویسد → tcp_rmem/wmem «تغییر» به‌نظر می‌رسیدید. **اصلاح شد**
  (مقایسهٔ whitespace-normalized).
- **Rollback بعد از اصلاح — اثبات زندهٔ تکرارپذیر:**
  ```
  before: somaxconn=32768 → apply → 8192 → rollback → 32768  ✓ (بازگشت دقیق)
  ```
- **Ownership و پاک‌سازی:** فایل owned که توسط همان apply ایجاد شده بود، با rollback حذف شد؛
  در پایان آزمایش میزبان به حالت اول برگردانده شد (somaxconn=32768، بدون فایل owned باقی‌مانده).

## ۵. Rollback هنگام قطع اتصال (network namespace واقعی)

`unshare -n` → netns ایزوله (فقط loopback، بدون egress) → apply داخل آن:
connectivity-guard فعال شد، **۱۱ تنظیم به‌طور خودکار rollback شد**،
journal ثبت کرد `rolled_back=true, verified=false`، کد خروج apply=1.
رفتار ایمن در شرایط تخریب‌شدهٔ شبکه تأیید شد. (تست hermetic معادل هم موجود است.)

## ۶. Persistence بعد از Reboot

بعد از apply، فایل owned در `/etc/sysctl.d/` موجود بود؛ `wsl --terminate` + راه‌اندازی مجدد:
```
after distro restart: somaxconn=8192   ← drop-in owned توسط systemd-sysctl در بوت اعمال شد ✓
```
**نکتهٔ عملیاتی (یافتهٔ شمارهٔ ۳):** journal/baseline در تست زیر `/tmp` بود و با ری‌استارت پاک شد.
در production مسیر journal زیر `/etc/gre-panel` (ماندگار) است؛ محدودیت: اگر configDir روی tmpfs باشد،
`netopt status` بعد از ری‌بوت «no journal» می‌گوید (مقادیر کرنل با drop-in پایدار می‌مانند).

## ۷. مرزهای مالکیت — SSH / فایروال / MTU / MSS

- md5 مقایسه‌ای قبل/بعد از apply+rollback: `UFW UNTOUCHED`، `SSHD_CONFIG UNTOUCHED`، `MTU UNTOUCHED`.
- `IPTABLES DIFFERS` — **محیطی و غیرمرتبط با netopt**: اثبات شد که جدول iptables این میزبان
  بدون هرگونه action از netopt هم تغییر می‌کند (دو snapshot متوالی با ۸ ثانیه فاصله متفاوت بودند)؛
  در کد netopt هیچ فراخوانی iptables/ufw/ssh وجود ندارد (تست `TestAcceptNeverTouchesForbiddenDomains`).
- هیچ پروفایلی کلید rp_filter، MTU، یا MSS پیشنهاد نمی‌کند؛ `tcp_mtu_probing` (کلید رفتار PMTU،
  نه تغییر MTU) مجاز و در Conservative/Balanced موجود است.

## ۸. سازگاری با Tinc/Matrix و مسیرهای نامتقارن

تشخیص، اینترفیس‌های qmx*/tun* را کلاس `tunnel` می‌بیند (MTU=qmx در fixture: 1380 ثبت شد)،
پروفایل‌ها هیچ اقدامی روی اینترفیس تونل انجام نمی‌دهند و rp_filter را لمس نمی‌کنند —
تست‌شده در `TestAcceptNoRpFilterOnAsymmetricTunnelHosts`.

## ۹. Ubuntu 26.04 و ARM64 و رگرسیون یکپارچه‌سازی

- **26.04:** کل مجموعهٔ تست‌های hermetic netopt روی distro 26.04.1 **PASS**؛ detect/plan
  فقط‌خواندنی درست کار کرد و تفاوت واقعی 26.04 را دید (qdisc پیش‌فرض `fq_codel` → پیشنهاد `fq`).
- **ARM64:** کراس‌کامپایل OK (ELF aarch64)؛ اجرا ممکن نبود (بدون QEMU/hardware).
- **رگرسیون روی SHA یکپارچه `deaf2b3`** (HEAD فعلی feature branch که merge نشست ۲
  یعنی `70f7bd8` و کارهای نشست ۱ و ۶ در آن است): build OK، vet تمیز، تست‌های netopt ادغام‌شده **PASS**.
  **هشدار برای integration:** دو اصلاح `0ccb70d` (باگ rollback) و `a40f7f7` (تست‌های پذیرش)
  هنوز در `deaf2b3` نیستند — در `deaf2b3` باگ کوتیشن rollback هنوز موجود است (بررسی کد شد).

## ۱۰. ادعاهای کارایی

**هیچ ادعای بهبود کارایی مطرح نمی‌شود.** طبق `docs/NETOPT-PERF.md`، هر ادعا نیازمند
before/after تکرارپذیر روی زوج واقعی ایران-خارج با harness است؛ در این پذیرش چنین
اندازه‌گیری روی سرور واقعی انجام نشد (ممنوع بود).

## ۱۱. عیوب باز (unresolved)

1. **کوتیشن rollback و مقایسهٔ whitespace در SHA یکپارچه رفع نشده** — نیاز به merge
   `0ccb70d` (در شاخهٔ من موجود و تست‌شده).
2. **فایل journal روی configDir ناپایدار (tmpfs) از بین می‌رود** — production مشکلی ندارد،
   ولی یک guard یا هشدار در `netopt status` می‌تواند اضافه شود (اختیاری).
3. **اجرای ARM64 تست نشد** (نبود qemu/hardware) — فقط build.
4. **تفاوت کرنلی 26.04** (کرنل جدید) تست نشد — WSL2 کرنل مشترک دارد؛ نیاز به VM واقعی 26.04
   در آینده.
5. **apply به root نیاز دارد** — طبیعی است (مثل بقیهٔ عملیات میزبانی پنل) ولی باید در
   docs نصب (Session 6) ذکر شود.

## ۱۲. دستورات دقیق (خلاصه)

```
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o gre-panel .
GRE_PANEL_DIR=<cfg> gre-panel netopt detect | plan | apply | status | rollback | revert
go test -run 'TestNet|TestAccept' -count=1 .
unshare -n /tmp/netns-apply.sh          # تست قطع اتصال
wsl --terminate Ubuntu-24.04            # تست reboot persistence
```
