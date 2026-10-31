#!/usr/bin/env bash
# tests/test_firewall_lab.sh — the firewall & port engine on a real kernel,
# inside a disposable network namespace of its own (fwlab): real backend
# detection, real iptables rules, real listeners, real idempotency and
# teardown, and the administrator-rule preservation guarantee. Needs root,
# iproute2 and iptables; skips cleanly otherwise. ufw/nft sections run
# only when those tools exist in the namespace.
# FIREWALL_LAB_TEST_BIN: a prebuilt `go test -c` binary of panel/ (else it
# is built here).
set -u
cd "$(dirname "$0")/.." || exit 1
[[ $EUID -eq 0 ]] || { echo "SKIP test_firewall_lab (needs root)"; exit 0; }
command -v iptables >/dev/null && command -v ip >/dev/null || { echo "SKIP test_firewall_lab (iptables/iproute2 missing)"; exit 0; }
BIN=${FIREWALL_LAB_TEST_BIN:-}
if [[ -z $BIN ]]; then
  BIN=/tmp/quantum-fw-lab.test
  (cd panel && go test -c -o "$BIN" .) || exit 1
fi
NS=fwlab-$$
ip netns add "$NS" || { echo "SKIP test_firewall_lab (cannot create netns)"; exit 0; }
cleanup() { ip netns del "$NS" >/dev/null 2>&1 || true; }
trap cleanup EXIT
ip -n "$NS" link set lo up
run() { ip netns exec "$NS" env QUANTUM_FW_LAB=1 "$@"; }
fails=0

run "$BIN" -test.run 'TestFirewallLabIptablesLifecycle' -test.v || fails=$((fails+1))
run "$BIN" -test.run 'TestFirewallLabListenerConflicts' -test.v || fails=$((fails+1))

if ip netns exec "$NS" sh -c "command -v nft >/dev/null"; then
  run "$BIN" -test.run 'TestFirewallLabNftReads' -test.v || fails=$((fails+1))
else
  echo "SKIP nft section (nft missing in the namespace)"
fi
if ip netns exec "$NS" sh -c "command -v ufw >/dev/null"; then
  run "$BIN" -test.run 'TestFirewallLabUfwDetection' -test.v || fails=$((fails+1))
else
  echo "SKIP ufw section (ufw missing in the namespace)"
fi

if [[ $fails -eq 0 ]]; then
  echo "test_firewall_lab PASS"
else
  echo "test_firewall_lab FAILED ($fails failing section(s))"
  exit 1
fi
