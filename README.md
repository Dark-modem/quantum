<div align="center">

# Hashem Panel

**Tunnels between an Iran server and foreign servers, managed from one web panel.**

Users connect to the Iran server's public IP; their traffic reaches services on your foreign servers through GRE, FRP, Backhaul, Xray, SSH or a spoofed pipe, with health checks, failover and safe updates built in.

<img src="docs/img/dashboard.png" alt="Hashem dashboard: one Iran server, four foreign servers, live traffic" width="900">

</div>

## How it works

```mermaid
flowchart LR
    U([Users]) --> HUB
    subgraph IR["Iran server"]
        HUB["Public ports<br/>frps · Backhaul · Xray"]
        P["Panel :7777"]
    end
    HUB <== "GRE · 6to4 · 4in6 · WSS" ==> A["Foreign server A<br/>FRP over GRE"]
    HUB <-- "Backhaul, no GRE" --> B["Foreign server B"]
    HUB <-- "Xray / SSH" --> C["Foreign server C"]
```

The **Iran server** owns the public ports users connect to. Each **foreign server** runs your services (for example an Xray panel) and is linked to the Iran server by a tunnel. The same panel runs on both sides: you set up the Iran server, copy one **setup bundle**, and paste it on the foreign server.

## Tunnels

| Tunnel | How it travels | Pick it when |
| --- | --- | --- |
| **GRE + FRP** | FRP over a GRE link (tcp, kcp, quic, websocket, wss) | the default: most options, free |
| **Backhaul** | with or without GRE (tcpmux, ws, wss, udp, …) | GRE is blocked, or you want Backhaul's transports |
| **Xray** | VLESS with Reality, XHTTP, gRPC, mKCP or a CDN | the path needs to look like normal HTTPS |
| **Bagher** | FRP inside a pool of SSH connections | only SSH gets through |
| **Spoof** | spoofed-source pipe with WireGuard on top | the firewall whitelists source IPs |

The GRE link itself can be wrapped four ways: **Direct** (protocol 47), **WSS** (TLS on a web port), **6to4** (protocol 41) and **4in6** (over IPv6). Not sure what gets through? **Path test** (Benchmark tab) checks every transport between your two servers before you build anything. Details: [docs/ENGINES.md](docs/ENGINES.md).

## Features

- **One health model** for the dashboard, the map and every card, with latency per link and alerts by webhook or Telegram when a tunnel changes state.
- **Swap a tunnel's carrier** from either server; both switch, and both go back if the new one does not connect within 45 seconds.
- **Cluster:** several foreign servers behind one Iran port (failover, balance, sticky, least connections), Iran servers backing each other up, and DNS failover. [Guide](docs/CLUSTER.md)
- **Watchdog, encrypted backups and diagnostics** (`hashem doctor`), with Quick Repair.
- **Updates you can undo:** stable and dev channels, SHA-256 verified, automatic rollback after a bad start.
- **Hardened panel:** argon2id passwords, CSRF, optional 2FA, audit log; the web terminal is off by default.
- **Everything from SSH too:** `hashem` opens a terminal app with the same menus as the panel.

## Quick install

The repository is private, so the installer needs a read token. Create a fine-grained token with **Contents: Read-only** on this repo (GitHub → Settings → Developer settings → Fine-grained tokens), then run on **both** servers:

```bash
read -rsp 'Quantum GitHub token: ' GRE_GITHUB_TOKEN; echo
export GRE_GITHUB_TOKEN
qinstaller=$(mktemp)
printf 'header = "Authorization: Bearer %s"\n' "$GRE_GITHUB_TOKEN" |
  curl --config - -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
    -H 'Accept: application/vnd.github.raw+json' \
    'https://api.github.com/repos/Dark-modem/quantum/contents/install.sh?ref=main' \
    -o "$qinstaller" && bash "$qinstaller"
rm -f "$qinstaller"
unset GRE_GITHUB_TOKEN
```

Run as root. The token is entered privately, without putting it in shell history. The installer uses GitHub directly (no private-repository mirrors), falls back from raw.githubusercontent.com to the GitHub Contents API, and stores the token with mode 600 for future updates. To test downloads without installing, run the downloaded script with `--check`.

1. **Iran server:** choose `1`, pick the tunnel and ports, and copy the bundle it prints (`hsh1_…`).
2. **Foreign server:** choose `2` and paste the bundle.
3. **Open the panel** at the URL printed at the end (`http://<server-ip>:7777/<secret>`). Lost it? `hashem show-panel-url`; new password: `hashem reset-password`.

More foreign servers are added from the panel's **Setup** tab. To read the installer first, or pin it to a release's `checksums.txt`, see [Installing safely](docs/OPERATIONS.md#installing-safely).

> [!IMPORTANT]
> The panel uses plain HTTP on a long random path by default. Before exposing it, add TLS with `hashem tls issue <domain>` or a reverse proxy ([docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)).

## Requirements

- Linux with systemd, `amd64` or `arm64` (developed on Ubuntu), and root on both servers. The installer adds missing packages.
- The GitHub releases reachable from both servers, for install and updates.
- Between the servers, whatever your tunnel uses:

| Tunnel or wrap | Open |
| --- | --- |
| Direct GRE · 4in6 | IP protocol 47 (over IPv4 · over IPv6) |
| 6to4 | IP protocol 41 |
| WSS wrap | TCP `8443` (default) |
| FRP · Backhaul · Xray | the control port you choose (UDP too for kcp, quic, udp) |
| Panel | TCP `7777`, or `7443` once HTTPS is on |

## Documentation

| | |
| --- | --- |
| **Start** | [Choosing a tunnel](docs/ENGINES.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Secure deployment](docs/DEPLOYMENT.md) |
| **Guides** | [IPv6](docs/IPV6.md) · [Xray tunnel](docs/XRAY_TUNNEL.md) · [Cluster](docs/CLUSTER.md) · [Cluster tutorial](docs/CLUSTER_TUTORIAL.md) · [FRP transports](docs/FRP_TUNNELS_GUIDE.md) |
| **Reference** | [Operations: health model, updates, CLI, uninstall](docs/OPERATIONS.md) · [HTTP API](docs/API.md) · [Error codes](docs/ERROR_CODES.md) · [Changelog](CHANGELOG.md) |
| **Project** | [Contributing](CONTRIBUTING.md) · [Development](docs/dev/DEVELOPMENT.md) · [Security policy](SECURITY.md) · [Code of conduct](CODE_OF_CONDUCT.md) |

Persian versions exist for the README and the IPv6, Xray, cluster and FRP guides.

