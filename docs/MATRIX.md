# Quantum Matrix tunnel

Matrix-Network is based on **tinc**, not rathole. Quantum uses tinc directly rather than executing the upstream interactive script (which modifies SSH settings and globally flushes NAT rules).

## Setup

1. Open **Tunnels → Add Tunnel**. Choose the **Matrix tunnel · IPv4 / IPv6** shortcut to the Matrix form.
2. On Iran, select IPv4 or IPv6 (the outer transport), a free control port (1024–65535, default 2097), and 1–20 forwarded TCP/UDP ports. SSH and panel ports are rejected; occupied ports are rejected before setup.
3. Apply, then copy the complete `hmx1_` bundle into the Matrix registration field on the foreign panel.
4. Open the Matrix row in Tunnels to view its role, family, service, mesh nodes, ports and Restart/Remove actions.

IPv6 means **tinc connects between the servers' global IPv6 addresses**. User port forwarding still accepts the Iran server's IPv4 and reaches the foreign server over the private IPv4 mesh. It does not mean IPv6-only public user listeners.

## Multiple Matrix instances on one server

A server may host **multiple independent Matrix tunnels** (one per topology). The legacy first instance keeps every historical name: network `quantum_matrix`, interface `qmx0`, mesh `10.254.231.0/30`, unit `quantum-matrix.service`, state `/etc/gre-panel/matrix.json`, config `/etc/gre-panel/matrix-tinc/`. Additional instances are created only when the caller explicitly asks for one and are fully disjoint from the legacy instance and from each other:

| Resource | Legacy (`matrix`) | Instance `matrix2` | Instance `matrixN` |
| --- | --- | --- | --- |
| tinc network | `quantum_matrix` | `quantum_matrix2` | `quantum_matrix<N>` |
| Interface | `qmx0` | `qmx2` | `qmx<N>` |
| Mesh subnet | `10.254.231.0/30` | `10.254.232.0/30` | `10.254.(230+N).0/30` |
| Service unit | `quantum-matrix.service` | `quantum-matrix2.service` | `quantum-matrix<N>.service` |
| Firewall chains | `QMX_IN/OUT/FWD/MSS` | `QMX2_*` | `QMX<N>_*` |
| Config directory | `matrix-tinc/` | `matrix2-tinc/` | `matrix<N>-tinc/` |
| State file | `matrix.json` | `matrix2.json` | `matrix<N>.json` |
| Local-service registry | `matrix-local-services.json` | `matrix2-local-services.json` | `matrix<N>-local-services.json` |
| Local bridge units | `quantum-matrix-local-<port>.service` | `quantum-matrix2-local-<port>.service` | `quantum-matrix<N>-local-<port>.service` |

Up to 16 extra instances are allowed per server (matrix2 … matrix17). Instances share nothing mutable: keys, ports, pidfiles and firewall chains are per instance, so removing one instance never touches another.

### API surface

- `GET /api/matrix/status` keeps its legacy top-level fields (the first instance) and adds `instances`: the public state of every instance, each with an `id`.
- `GET /api/matrix/instances` lists every instance with its public state.
- `POST /api/matrix/setup` accepts `instance`: omit it (or `"matrix"`) for legacy behavior, `"next"` to allocate the lowest free ID, or an explicit `matrix2`, `matrix3`, … ID. Setup refuses an instance that is already enabled, ports already owned by another Matrix instance, and ports owned by any topology's tunnel.
- `POST /api/matrix/foreign-setup` derives the instance from the bundle's `network` field; the bundle's mesh IP must match that instance.
- `POST /api/matrix/edit`, `POST /api/matrix/remove`, `POST /api/matrix/restart` and `POST /api/matrix/local-service` accept an optional `instance` (default: the legacy instance).
- `POST /api/matrix/register` is unchanged for the legacy instance; with several hub instances the registration **token selects the instance**, so each hub instance still pairs exactly one node.

Foreign nodes apply bundles per instance: each instance on a node is bound to one hub and one topology. Edit/remove/restart on a hub affect only that hub's instance and its bundle.

### Port ownership rules

New Matrix instances (and edits that add forwarded ports) refuse any port that (a) is already in another Matrix instance's state (even if that instance is stopped) or (b) belongs to a tunnel bound to any topology. Conversely, creating or editing peer/main tunnels refuses ports reserved by any Matrix instance. The mesh port of each instance must also be unique and free at setup time; the caller chooses it explicitly.

## Editing

Open the Matrix row → **Edit**. On the Iran hub you can change the forwarded ports or outer transport family/address without regenerating keys or node identity. New occupied ports are rejected. Port-only edits update the forwarding rules without restarting the transport.

A family/address change is staged: the hub returns an updated pinned bundle and marks peer synchronization pending. Copy that bundle into **Edit** on the foreign node to complete the switch. Expect a brief interruption while the two ends use different transport families. A different hub key is rejected; pairing another node still requires a new setup. Failed local edits restore the previous owned configuration.

Matrix is included in Dashboard/status/fleet snapshots even when no GRE/FRP tunnel exists. Running service and confirmed mesh connection are reported separately; qmx0 counters supply the Matrix traffic values.

## Connecting Xray or another loopback-only service

On the foreign panel, open **Matrix → View → Edit → Connect a local service to Matrix**. Enter the Matrix user port and local service port (443 → 443 for the current Reality inbound). The panel creates a dedicated TCP bridge from `10.254.231.2:443` to `127.0.0.1:443`. Xray can remain bound to loopback: its configuration, UUID, Reality keys and service are not modified.

The hub must already forward that user port, and the local destination must accept TCP connections. The bridge is bound only to the mesh IP, not the foreign public IP. Dedicated `quantum-matrix-local-<port>.service` units follow Matrix restart and are removed with Matrix. **Remove local bridge** removes the bridge independently. UDP service bridging is not implemented here.

This connects an Xray inbound already present on the foreign server. It does not move an Iran-only inbound; that still requires an explicit migration/cutover.

## Isolation and removal

Owned resources (shown for the legacy instance; every extra instance `matrixN` owns the `matrixN`-suffixed equivalents listed above):

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
