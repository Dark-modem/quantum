# Network Optimization — Legacy Inventory, Policy and Profiles

Session 2 deliverable. This document is the inventory the `gre-panel netopt`
subsystem was built from: what the owner's provisioning script and Quantum's
own installer tuning do, what is worth preserving as a *concept*, what is
unsafe or incompatible and must never be reproduced, and the product policy
for Nginx.

Sources inspected (nothing was executed):
- `node-setup/nginx/setup.sh` (2015 lines, "VPN Node Ultimate Architect Suite v14.2")
- `node-setup/nginx/nginx.conf`, `node-setup/nginx/default.conf`
- `quantum.sh` tuning functions (`tune_apply`, `tune_scale_values`,
  `tune_backup_once`/`tune_restore`, `reserve_service_ports`, `free_ram`)
- The first real Matrix tunnel measurements (see `NETOPT-PERF.md`)

---

## 1. Legacy inventory — useful concepts (preserved into netopt)

| Legacy concept | Where | Preserved as |
|---|---|---|
| BBR + fq pair | quantum.sh `tune_apply` | Balanced/Performance default, gated on *read-back* availability of `bbr` (`/proc/sys/net/ipv4/tcp_available_congestion_control`) |
| RAM-scaled kernel targets | quantum.sh `tune_scale_values` (mem×128 conntrack, clamped) | `conntrackMaxFor()` — clamped tighter (64K–512K) than both legacy variants |
| Backup before change + restore | quantum.sh `tune.bak` / `tune_restore` | netopt journal + baseline (per-key previous values, owned-file contents), `rollback`/`revert` |
| Service ports out of ephemeral range | quantum.sh `reserve_service_ports` | `netReservedPortsValue()` resolves panel/FRP/Backhaul/agent-tunnel ports from live config; skipped when nothing is known |
| Read-back verification of every sysctl | node-setup `apply_sysctl_file` | `netVerifySysctl` after every apply; mismatch = failure = rollback |
| Owned drop-in files, never appended | node-setup `/etc/sysctl.d/99-node-*.conf` | one owned file `/etc/sysctl.d/99-quantum-netopt.conf` with a managed marker |
| Boot-time re-application of NIC state | node-setup `node-ultimate-optimizer.service` | owned oneshot unit `quantum-netopt-nic.service` (only created when NIC actions were applied) |
| virtio-aware NIC handling | node-setup (skip ring/channel/coalescing on virtio_net) | detection classifies `virtio` and the requirements gate NIC candidates on a *physical* primary NIC |
| TCP buffers sized to RAM, not fantasy | node-setup comment "sane ceilings for a 4GB box" vs quantum 16 MB | Balanced sets 16 MB ceilings (quantum value); Conservative touches no buffers |
| THP `madvise` via sysfs | node-setup tuner | documented as a safe optional; not in profiles by default (needs measured justification) |
| irqbalance enable | node-setup | documented optional; belongs to the installer domain (Session 6) if adopted |
| MSS clamp on tunnel paths | quantum.sh (POSTROUTING + per-GRE) | stays with the tunnel code — netopt does **not** touch mangle rules |
| MTU discipline: never downscale blindly | node-setup `[3.2]` + quantum GRE MTU 1380 | netopt records MTU in detection but **never changes it** |

## 2. Legacy inventory — dangerous or incompatible (rejected)

| Legacy behavior | Where | Why rejected |
|---|---|---|
| `ufw --force reset` + closed allowlist | node-setup step 2 | destroys existing rules; only 80/443/52587 open — kills panel/tinc/FRP/Backhaul ports. **Firewall is Session 1's; netopt never touches it.** |
| SSH hardening block (port 52587, root off, key gen with hardcoded passphrase `1382Asll!`) | node-setup step 1 | lockout risk; hardcoded secret. **SSH is Session 6's; netopt never touches it.** |
| `rp_filter=1` (strict) on a forwarding/tunnel box | node-setup sysctl | drops asymmetric tunnel traffic (GRE/tinc); incompatible with the data plane |
| ICMP echo-request DROP in before.rules | node-setup | breaks latency probing and PMTUD-visible health checks |
| `ethtool -A rx off tx off` (checksum offload OFF) | node-setup tuner | burns CPU for no gain; a nonstandard choice for one specific NIC |
| Conflicting keepalive values: node-setup 600/30/3 vs quantum 30/10/5 | node-setup 99-node-network.conf vs quantum.sh `tune_apply` | **netopt deliberately sets 600/30/5 (Balanced)** with the recorded reason: liveness is app-level (agent heartbeat over WSS), and calm keepalives reduce periodic probe traffic on DPI'd paths. The conflict is resolved consciously, not inherited. |
| Fixed conntrack 524288 on every box | node-setup | ~150 MB worst case on a 1 GB VPS; netopt scales by RAM (64K–512K) |
| `udp_mem` fixed small values | node-setup | breaks QUIC/UDP-heavy nodes with more RAM; not in any profile |
| `net.ipv4.tcp_syn_retries=2`, `tcp_orphan_retries=3`, `thin_linear_timeouts=1`, fixed `tcp_max_tw_buckets=262144` | node-setup | single-box micro-tuning; wrong on other hardware; no measured justification |
| `min-cache-ttl=300` in dnsmasq | node-setup step 5 | breaks fast DNS failover (health-driven switching needs fresh answers) |
| Disabling `systemd-resolved` + static resolv.conf | node-setup steps 2/5 | fights netplan; a DNS outage reads as a network outage in every health check |
| CAKE qdisc as default replacement for fq | node-setup tuner | conflicts with `default_qdisc=fq` + BBR pacing; **kept as an opt-in** (`--qdisc cake` in a future increment) for measured bufferbloat only |
| `net.core.rps_sock_flow_entries` without per-queue `rps_flow_cnt` | node-setup | a global no-op; netopt only proposes RPS when per-queue files exist (detection checks) |
| `worker_cpu_affinity auto`, `ssl_session_cache shared:SSL:20m` on every endpoint | nginx.conf | controller-only concerns; pointless RAM on agents |
| installing nginx on every server | node-setup dependency step | see §3 |

## 3. Nginx product policy (defined, not installed)

1. **Central Controller uses Nginx for HTTPS/WSS.** The controller is the
   public TLS edge: Nginx terminates 443, the panel serves its listeners
   behind it per the deployment design. Controller Nginx tuning (worker
   limits, keepalive, backlog) belongs to the controller's profile and the
   installer — **not** to `netopt apply`.
2. **Endpoint Agent does not need Nginx by default.** An agent has no web
   UI; its WSS session is an *outbound* client connection to the controller.
   Installing Nginx on an agent is pure attack surface and RAM.
3. **Optional endpoint Nginx is justified only by a specific transport mode**
   — e.g. an Iran endpoint that fronts a decoy/WS ingress behind Cloudflare
   (the legacy `Client → CF → Nginx → Xray` model). If that mode ships, it
   ships as an explicitly requested role capability, never as part of
   network optimization.

This subsystem neither installs nor modifies Nginx on any server. The two
legacy nginx files remain reference material for the optional endpoint mode.

## 4. The profiles

Selection is hardware-aware and explainable (`netopt plan` prints the
reasons; the journal records them):

- **Conservative** — stability and compatibility. Applied when: facts are
  incomplete (>3 detection warnings), memory pressure (available < 15%),
  RAM < 2 GB, or unknown virtualization. Touches only: somaxconn/syn
  backlog 4096, `tcp_mtu_probing=1`, swappiness 10.
- **Balanced** — default for a fully-measured server. Adds: BBR+fq (only if
  the kernel exposes bbr), 16 MB socket ceilings + auto-tuned tcp_rmem/wmem
  (RAM ≥ 2 GB), backlog 16384, RAM-scaled conntrack, calm keepalives
  600/30/5, service-port reservation, swappiness 10.
- **Performance** — only when the hardware case is *measured*: bbr
  available, ≥ 4 cores, ≥ 8 GB RAM, physical NIC present, bare metal
  (virtualized hosts get Balanced — their NICs are paravirtual and
  host-shaped). Adds: deep backlog 65535, controller somaxconn 16384,
  `tcp_notsent_lowat`, **TCP Fast Open (with the recorded DPI caveat)**,
  NIC ring buffers raised to the maximum (physical, headroom required),
  RPS on a single-queue multi-core primary. An operator can force it with
  `--profile performance --justify "..."`, and the justification is
  journaled.

Every candidate carries `Needs` (machine-checked), `Reason` and `Risk`
(journaled). No-ops (already at the target value) are reported, not applied.

## 5. Apply / rollback contract

1. `detect` — fresh measurement (never cached).
2. `plan` — profile + per-setting diff (current → proposed, apply/skip+why).
3. `apply` — capture baseline (per-key previous value + owned-file contents +
   full detection snapshot) → write owned drop-in → `sysctl -p` → read-back
   verify every key → NIC actions via ethtool (verified by re-read) → owned
   boot unit when NIC state changed → **connectivity probe** (loopback canary
   + egress dial through the shared dial seam) → on ANY failure: full
   automatic rollback and a journal marked `rolled_back`.
4. `status` — journal vs live drift.
5. `rollback` — undo the last apply from the baseline.
6. `revert` — restore owned-file contents (or remove files this apply
   created) and restore every captured value: full return to pre-netopt.

Persistence: sysctls survive reboot via the owned drop-in; NIC registers via
the owned oneshot unit (`ExecStart=gre-panel netopt apply-nic`, replaying the
journaled NIC actions only).

Out of scope, permanently: SSH, firewall, port rules (Sessions 1/6), MTU and
MSS (tunnel code), Nginx installation (§3).
