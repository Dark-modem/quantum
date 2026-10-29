#!/usr/bin/env bash
# Regression test for H-01: obsolete quantum-monitor/webui units must be removed.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sd/multi-user.target.wants"
printf '#!/bin/sh\necho "$@" >> %s/systemctl.log\n' "$T" > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
export PATH="$T/bin:$PATH" QUANTUM_SYSTEMD_DIR="$T/sd" GREEN= NC=
awk '/^remove_legacy_units\(\) \{/,/^}/' "$ROOT/quantum.sh" > "$T/fn.sh"
[[ -s "$T/fn.sh" ]] || { echo "FAIL: remove_legacy_units not found in quantum.sh"; exit 1; }
# shellcheck disable=SC1091
source "$T/fn.sh"
fail=0
mk() { printf '[Service]\nExecStart=%s\n' "$2" > "$T/sd/$1.service"; }
mk quantum-monitor "/usr/local/bin/quantum --monitor"
mk quantum-webui "/usr/local/bin/quantum --webui"
mk gre-panel "/usr/local/bin/gre-panel"
mk quantum-custom "/usr/local/bin/quantum restart"
remove_legacy_units
[[ ! -e "$T/sd/quantum-monitor.service" ]] || { echo "FAIL monitor kept"; fail=1; }
[[ ! -e "$T/sd/quantum-webui.service" ]] || { echo "FAIL webui kept"; fail=1; }
[[ -e "$T/sd/gre-panel.service" ]] || { echo "FAIL gre-panel removed"; fail=1; }
[[ -e "$T/sd/quantum-custom.service" ]] || { echo "FAIL unrelated quantum unit removed"; fail=1; }
grep -q 'daemon-reload' "$T/systemctl.log" || { echo "FAIL no daemon-reload"; fail=1; }
remove_legacy_units || { echo "FAIL not idempotent"; fail=1; }
# a monitor unit with a different, valid ExecStart must be preserved
mk quantum-monitor "/usr/local/bin/quantum watchdog run"
remove_legacy_units
[[ -e "$T/sd/quantum-monitor.service" ]] || { echo "FAIL valid monitor unit removed"; fail=1; }
(( fail )) && exit 1; echo "PASS test_legacy_units"
