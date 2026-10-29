# Quantum Matrix tunnel

Matrix-Network is based on **tinc**, not rathole. Quantum uses tinc directly rather than executing the upstream interactive script (which modifies SSH settings and globally flushes NAT rules).

## Setup

1. Open **Tunnels → Add Tunnel**. Choose the **Matrix tunnel · IPv4 / IPv6** shortcut to the Matrix form.
2. On Iran, select IPv4 or IPv6 (the outer transport), a free control port (1024–65535, default 2097), and 1–20 forwarded TCP/UDP ports. SSH and panel ports are rejected; occupied ports are rejected before setup.
3. Apply, then copy the complete `hmx1_` bundle into the Matrix registration field on the foreign panel.
4. Open the Matrix row in Tunnels to view its role, family, service, mesh nodes, ports and Restart/Remove actions.

IPv6 means **tinc connects between the servers' global IPv6 addresses**. User port forwarding still accepts the Iran server's IPv4 and reaches the foreign server over the private IPv4 mesh. It does not mean IPv6-only public user listeners.

The current implementation supports **one Quantum Matrix pair per server**. Remove/recreate to change family or pair another node. It can coexist with other tunnel engines provided the ports and private subnets do not overlap.

## Isolation and removal

Owned resources:

- `/etc/gre-panel/matrix-tinc/` (configuration, RSA key, host public keys, startup scripts)
- `/etc/gre-panel/matrix.json` (0600 state)
- `/etc/systemd/system/quantum-matrix.service`
- `qmx0`, mesh `10.254.231.0/30`
- `QMX_IN`, `QMX_OUT`, `QMX_FWD`, `QMX_MSS` firewall chains and tagged jumps

Removal stops/disables only the owned service, removes its interface/routes, deletes only the dedicated firewall chains and the owned files. Existing tinc networks, `/etc/tinc/matrix`, SSH configuration, Xray, the panel, and unrelated NAT rules are preserved. The shared tinc package is not uninstalled. Remove each side separately.

Restart restores forwarding through an idempotent startup script. Failed registration cleans the newly created node. Resource conflicts are refused rather than overwritten.

## Security

- Authentication uses RSA public keys; data cipher AES-256-CBC with SHA-256 digest (tinc 1.0 protocol).
- The bundle includes the hub public key; imported tinc directives are discarded and regenerated from validated values.
- Registration pins one node's key; subsequent attempts with a different identity are rejected.
- The bundle is a credential. Transfer it securely. Use HTTPS for the panel or an SSH tunnel; plain HTTP does not protect the registration token.

## Verification (2026-10-29)

Both IPv4 and IPv6 outer transports were tested on Iran amd64 / foreign arm64:

- Bidirectional mesh ping.
- Exact 128 KiB TCP echo from the laptop through Iran's public port.
- 20 exact 1024-byte UDP echo datagrams through the same forwarding path.
- Repeat of TCP/UDP after restarting both Matrix services.
- Removal of both ends, confirming no `qmx0`, listener, owned service/configuration or QMX firewall chain remained.
- Previous firewall rules and effective default routes were unchanged; legacy tinc files were retained.

These tests verify the tested configuration, not every ISP/network condition or high-load profile.
