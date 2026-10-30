# Central Controller & Endpoint Agents

Quantum's agent architecture: **one central controller** (the full Quantum
panel on the Iranian server) orchestrates **lightweight agents** on tunnel
endpoints. An endpoint runs no web panel — only `gre-panel agent`, a headless
mode of the same binary that dials the controller outbound and manages the
local Matrix (tinc) tunnel.

```
                    ┌────────────────────────────┐
   browser ─HTTPS──▶│  Central controller (Iran) │
                    │  gre-panel + agent hub     │◀──WSS──┐
                    └───────────┬────────────────┘        │
                                │ desired state            │ outbound WSS
                                ▼                          │ (agent dials)
                    ┌────────────────────────┐   ┌─────────┴──────────┐
                    │ Iran agent (hub role)  │   │ Foreign agent      │
                    │ gre-panel agent run    │   │ (node role)        │
                    │ quantum-matrix.service │◀──│ quantum-matrix     │
                    │ tinc qmx0, DNAT ports  │──▶│ tinc qmx0, services│
                    └────────────────────────┘   └────────────────────┘
```

## Why this shape

- **One dashboard, many endpoints.** Enrollment, desired state, health and
  traffic for every endpoint are managed from the controller UI.
- **No inbound management ports.** Agents open zero listeners; they dial the
  controller over TLS (through nginx or the panel's own TLS listener).
- **Tunnels survive controller loss.** The Matrix tunnel is its own systemd
  unit (`quantum-matrix.service`). The agent stores its last valid desired
  state on disk and re-applies it on boot without any controller present.
- **No shell RPC.** Agents execute a fixed allowlist (`matrix.start/stop/
  restart/register`, `diag.ping`). Anything else is refused.

## Controller side

### Enrollment tokens

1. Dashboard → Agents → «ساخت توکن ثبت», pick role (ایران/خارج).
2. The token (`enr_…`) is shown **once**; it is single-use and expires
   (default 7 days). It only grants identity creation — it never carries
   tunnel capability.

### Agents API (session-authenticated)

| Method & path | Purpose |
|---|---|
| `GET /api/agents` | agent list (public view) |
| `GET /api/agents/{id}` | detail: last state report, health, traffic rates |
| `POST /api/agents/tokens` | create enrollment token |
| `GET /api/agents/tokens` | list tokens (prefix only) |
| `POST /api/agents/tokens/{id}/revoke` | revoke a token |
| `POST /api/agents/{id}/revoke` | revoke an agent (drops its session) |
| `POST /api/agents/{id}/command` | run one allowlisted command |
| `POST /api/agents/{id}/desired` | push desired state directly |
| `POST /api/agent/enroll` | agents only (enrollment-token auth) |
| `GET /api/agent/ws` | agents only (agent-key auth, WebSocket) |
| `GET /api/agent-tunnels` | agent-based tunnel list + health + traffic |
| `POST /api/agent-tunnels` | create a Matrix tunnel between two agents |
| `POST /api/agent-tunnels/{id}/power` | `{"active":true\|false}` both endpoints |
| `POST /api/agent-tunnels/{id}/restart` | restart Matrix on both endpoints |
| `DELETE /api/agent-tunnels/{id}` | remove tunnel; teardown desired to both |

### Agent-based Matrix tunnels

Creating a tunnel picks two agents (hub = Iran, node = foreign), allocates
the next free `matrix`/`matrix2`/… instance for that hub, generates the
pairing token and drives both endpoints through desired state:

1. **Hub desired** — role, family, mesh port (0 = agent auto-picks), public
   address, forwarded ports, token. The ack carries the hub's tinc
   `hosts/main` file.
2. **Node desired** — the proven `hmx1_` pairing bundle built from the hub
   ack (so the node reuses the exact provisioning path of the manual flow).
   The node applies it, then sends `register` (its host file) over the
   agent channel; the controller relays it to the hub as the
   `matrix.register` command. The node acks, and the tunnel is **active**.
3. **Verification is real, not cosmetic:** a tunnel is healthy when the hub
   agent's ICMP probes over the `qmx` interface to the node's mesh IP
   succeed — systemd being active alone is never "healthy".

Every desired state carries a unix-nano **revision**. Agents reject stale
revisions, treat equal revisions as idempotent no-ops, and persist pending
state so a reboot replays it.

## Endpoint side (agents)

```bash
# one-time
sudo gre-panel agent enroll --server https://panel.example.com --token enr_…
sudo gre-panel agent install        # writes + starts gre-agent.service

# the daemon
sudo gre-panel agent status
sudo journalctl -u gre-agent -f
```

- `agent.json` (0600) — identity: id, key, controller URL, TOFU TLS pin.
- `agent-state.json` (0600) — last desired state + applied revision.
- The agent reports every 30 s: matrix instances (service, interface, mesh
  pings), a 60-second health window (latency, jitter, loss — three ICMP
  packets per minute, nothing heavier), and `/proc/net/dev` counters split
  into physical NICs (billable) and tunnel interfaces (payload).
- Read-only PasarGuard Node detection is reported when present; the agent
  never touches containers, Docker config, or its systemd unit.

### Traffic accounting

On the Iran hub, **physical NIC RX is the billable direction**; the `qmx`
interface carries the payload. The controller derives byte rates from
consecutive heartbeats and exposes `billable_amplification`
(physical RX ÷ tunnel TX) on the tunnel view — shown as UNKNOWN whenever a
component cannot be measured. Traffic attribution never touches iptables:
counters come from the kernel via `/proc/net/dev`, and Matrix's own
firewall footprint stays inside its dedicated `QMX*` chains.

## Security model

- Agent keys are 48-hex random, stored only as SHA-256 hashes on the
  controller; auth uses constant-time comparison.
- TLS: agents verify normally **and** pin the controller leaf cert's SPKI
  (TOFU at enrollment) — a changed certificate is a hard stop.
- Revocation is immediate (the hub closes live sessions).
- The pairing token lives in `agent_tunnels.json` (0600) on the controller
  and in matrix state on the hub agent; it never appears in logs or API
  list views. Enrollment tokens are stored hashed, single-use.
- Every enroll/reject/auth-failure lands in the security audit log.

## Current limitations (MVP)

- Matrix is the only engine; the protocol (`agentproto.go`, v1) and the
  desired-state shape are engine-extensible by design.
- No automatic multi-path failover; the health model is already per-tunnel
  and per-window, ready for a second path later.
- Traffic history is derived from the latest heartbeat rates; long-range
  per-agent ledgers are a follow-up.
- The controller keeps one live WS per agent (newest wins).
