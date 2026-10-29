# Dashboard measurement scope

## Server dashboard

The main dashboard describes this server, not the currently selected topology.
CPU, RAM, disk and host connections remain server-wide. Network measurements
use eligible host-facing physical/virtio interfaces, including non-tunnel user
traffic. Loopback, Matrix `qmx0`, GRE, tunnel interfaces, bridges, veth pairs and
other stacked virtual interfaces are excluded from this physical-interface sum
so the same packet is not counted once on its tunnel and again on its transport.

`server_total` is received, transmitted and combined bytes **since reliable
recording began**, not an inferred all-time total, billing figure or migration
of the old tunnel counters. The first trustworthy sample establishes a baseline.
`server_window` is the recorded traffic for the requested time range. Missing
sources are unknown/N/A, not an invented zero; rates need comparable samples.
Retention and periods before recording limit available history. Existing tunnel
traffic counters and histories are separate and are not reset by this scope change.

## Topology usage

A topology is panel-only metadata grouping existing tunnels between two servers.
Its custom name is supported on creation and through a name edit. Its stable ID,
creation time and assignments do not change when it is renamed. Renaming is not
an engine rename, tunnel recreation, service restart or physical-metric reset.
Deleting a topology removes the grouping only; its tunnels remain running.

Per-topology usage is the requested-range sum of available recorded tunnel
counters for **current assignments** (`grouping_basis: current_assignments`).
It is not a historical assignment audit: attaching a tunnel can include that
link's earlier retained traffic; detaching it removes the same traffic from the
current group view. A rename changes the displayed group label without resetting
or relabeling the underlying link ledger. Matrix usage uses its `qmx0` counter
under the stable `matrix` identity; unknown or unavailable per-link counters
must not become estimated physical traffic.

Unassigned usage means recorded counters for currently unassigned tunnels. It
is **not** physical server traffic minus topology totals. Physical NIC traffic
and tunnel traffic measure different layers: transport overhead and unrelated
host/user traffic prevent exact reconciliation. Do not add the aggregate tunnel
`host` series to its per-link series, or add physical server traffic to topology
traffic, to calculate a grand total; doing so double-counts packets.

Metadata handlers use stored grouping data and cached inventory only. They do
not run host commands or active network probes. The detail/overview screens are
views over these measurements, not commands to alter the active Matrix443 bridge.
