# Topology grouping API

A topology is a panel-only group between this server and one remote server. It can contain multiple existing tunnels (for example, legacy FRP plus Matrix). It is **not** a tunnel configuration: creating, editing, assigning, detaching, and deleting a topology never starts/stops services, changes engine configuration, creates tunnels, or migrates legacy installations.

## HTTP contract

The parent panel mounts these handlers behind its existing authentication and mutation/CSRF protection, including its configured base path:

| Method | Route | Handler | Success response |
| --- | --- | --- | --- |
| GET | `/api/topologies` | `handleTopologiesGet` | 200 `{ "topologies": [...], "tunnels": [...] }` |
| POST | `/api/topologies` | `handleTopologiesPost` | 201 `{ "status": "ok", "topology": {...} }` |
| PATCH | `/api/topologies/{id}` | `handleTopologyPatch` | 200 `{ "status": "ok", "topology": {...} }` |
| DELETE | `/api/topologies/{id}` | `handleTopologyDelete` | 200 `{ "status": "ok", "id": "..." }` |

PATCH and DELETE read the ID from `r.PathValue("id")`. Errors are JSON `{ "error": "message" }`: 400 for invalid requests, invalid IDs, or tunnels absent from inventory; 404 for missing topology IDs; 409 for duplicate names, ownership/server mismatches, or the collection limit; 500 for unreadable/invalid stored data or failed persistence.

### Topology fields

```json
{
  "id": "topo_0123456789abcdef0123456789abcdef",
  "name": "Iran to foreign server",
  "role": "iran",
  "local_ip": "203.0.113.1",
  "remote_ip": "203.0.113.2",
  "tunnel_ids": ["main", "matrix"],
  "created_at": 1793232000
}
```

- `id`: server-generated cryptographically random safe string; immutable. IDs are never used as filenames.
- `name`: trimmed, nonempty, at most 120 Unicode characters, no control characters. Names must be unique across the collection, case-insensitively.
- `role`: exactly `iran` or `foreign`, describing this server's side of the pair.
- `local_ip`, `remote_ip`: empty for pending metadata, or IPv4/IPv6 literals. Stored IPs are canonicalized. Hostnames, ports, CIDRs, and scoped IPv6 addresses are not accepted.
- `tunnel_ids`: array of canonical existing inventory IDs; no duplicates. A tunnel belongs to at most one topology. An empty array means no associated tunnels.
- `created_at`: immutable Unix timestamp in seconds.

POST accepts only `name`, `role`, `local_ip`, `remote_ip`, and `tunnel_ids`. Missing fields default to `"New topology"`, `"iran"`, `""`, `""`, and `[]`, respectively. The client should supply a unique name when creating several pending groups.

PATCH accepts the same editable fields, with at least one field required. Unmentioned fields remain unchanged; providing `tunnel_ids` replaces the full association list. Null values, incorrect types, unknown/immutable fields, oversized bodies, and trailing JSON are rejected. Detach by PATCHing `{"tunnel_ids":[]}`; pending groups can then freely change their role/IP metadata.

### Association validation

Every newly submitted association must refer to current inventory. Known tunnel roles/local addresses must match topology metadata when supplied. A nonempty topology remote IP must match a known tunnel endpoint or an explicitly known alias. Tunnels with known endpoints must share a remote endpoint, even when the topology's `remote_ip` is still blank. A truly unknown endpoint does not prevent pending grouping.

Matrix `engine` stays `matrix`, with its transport family returned separately. For a Matrix node, the saved registration bundle's literal panel-host IP is an explicit alias for its hub's transport address: a v4 panel and v6 transport can therefore join the same group. No DNS lookups or arbitrary cross-family host guesses are performed.

Changing a group's role while retaining assigned tunnels is rejected; detach first. IP changes or resubmitted associations are checked against inventory. Name-only edits remain available if a configured tunnel has disappeared from the current snapshot. GET preserves such stale IDs rather than automatically removing or reassigning them.

### Delete confirmation

Suggested confirmation text:

> Delete this topology grouping? Its tunnels will remain configured and running, and can be assigned to another topology.

Deletion is allowed even when `tunnel_ids` is nonempty. It removes only metadata and releases ownership. There is deliberately no engine-resource deletion or `detach` confirmation flag.

## Tunnel inventory

Each inventory item exposes only display/status data:

```json
{
  "id": "matrix",
  "name": "Matrix",
  "engine": "matrix",
  "remote_ip": "2001:db8::2",
  "remote_ips": ["203.0.113.2"],
  "family": "v6",
  "state": "healthy",
  "latency_ms": 12.5,
  "ports": [443, 8443]
}
```

`family` and `remote_ips` are optional. `remote_ips` contains only explicitly known alternate IPs. Ports are integer arrays, including `[]` when none are known. Status is `healthy`, `degraded`, `down`, or `unknown`; unknown latency is `-1`.

Canonical IDs are `main` for the legacy base tunnel, `peer:<positive id>`, `matrix`, `bagher` for Bagher link 1/the legacy singleton, `bagher:<positive id>` for additional individually saved Bagher links, and `xray:<positive id>`. These identify existing resources, not topology-owned copies. Matrix-only installations never produce a phantom `main` item.

The inventory reads the existing published hub snapshot, saved Xray link records, and already-cached Xray health. It intentionally avoids the cold-start `currentSnapshot()` path and health helpers that initiate collection or probes. Before the first snapshot, snapshot-backed engines may be absent; GET does not launch commands, pings, network requests, or configuration migrations. Tokens, keys, bundles, expert configurations, and raw error text are never returned.

Tests can replace `topologyInventory`, whose signature is `func() []topologyTunnel`, with deterministic fixtures.

## Persistence and limits

Collection data lives only at `filepath.Join(configDir, "topologies.json")`:

```json
{ "topologies": [] }
```

An independent mutex serializes topology collection operations and exclusive ownership checks. Mutations write a fresh same-directory temporary file, set mode `0600`, flush and close it, then atomically rename it over the collection. Existing permissive collection modes are replaced by `0600`; failed replacement cleans up the temporary file and preserves the destination. Unix mode assertions are skipped on Windows, whose permission semantics differ.

GET never creates, repairs, or migrates a file. A missing collection is an empty list; corrupt collections fail closed and are not silently overwritten. There are at most 100 topologies, 1,000 association IDs per topology, a 64 KiB mutation body limit, and a 1 MiB stored collection limit. No active engine file or service is modified.

## Verification

From the panel directory:

```sh
go test ./... -run Topolog -count=1
```

Tests cover CRUD/reload, pending defaults, partial updates, strict input validation, exclusive/concurrent ownership, same-peer matching, Matrix v4/v6 registration aliases, collection limits, stale inventory, read-only GET, fail-closed corrupt persistence, atomic replacement/temporary cleanup, Unix `0600` permissions, canonical/no-secret inventory, and preservation of legacy engine files on deletion.
