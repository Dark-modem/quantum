#!/usr/bin/env bash
# tests/firewall_acceptance.sh — Session 1 final firewall engine acceptance,
# run inside a disposable network namespace on Linux (needs root, ip,
# iptables). Proves: the CLI fall-through hang root cause, unknown-command
# fast failure, dry-run non-mutation, engine apply/teardown with
# installer-owned tags (service:quantum-controller), audit trail, and
# unrelated-rule preservation. Binaries are overridable:
#   FW_NEW_BIN = current engine binary        (default /tmp/gre-new)
#   FW_OLD_BIN = pre-firewall 62ba5d5 binary  (default /tmp/gre-old)
# Build: (cd panel && go build -o /tmp/gre-new .)   [current main + patches]
#        (cd panel@62ba5d5 && go build -o /tmp/gre-old .)
set -u
NS=fwacc
NEW=${FW_NEW_BIN:-/tmp/gre-new}
OLD=${FW_OLD_BIN:-/tmp/gre-old}
export GRE_PANEL_DIR=/tmp/fwacc
fails=0
note() { echo "== $*"; }
good() { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fails=$((fails+1)); }

command -v ip >/dev/null && command -v iptables >/dev/null || { echo "SKIP (ip/iptables missing)"; exit 0; }
ip netns add "$NS" 2>/dev/null || true
ns() { ip netns exec "$NS" env GRE_PANEL_DIR="$GRE_PANEL_DIR" "$@"; }
nsv() { ip netns exec "$NS" "$@"; }
nsv ip link set lo up
nsv iptables -A INPUT -p tcp --dport 22 -j ACCEPT   # pre-existing administrator rule

note "1) HANG ROOT CAUSE — old binary (62ba5d5, no firewall subcommand)"
nsv sh -c "command -v $OLD >/dev/null || { echo 'old binary missing'; exit 97; }"
start=$(date +%s)
# Separate GRE_PANEL_DIR: the old binary's serve fall-through would itself
# create panel.json under the shared dir (second proof of the root cause).
nsv sh -c "env GRE_PANEL_DIR=/tmp/fwold timeout 6 $OLD firewall detect >/tmp/old-detect.out 2>&1"; rc=$?
elapsed=$(( $(date +%s) - start ))
if [[ $rc -eq 124 ]]; then
    good "old binary HIT the 6s timeout (exit 124, ${elapsed}s) — with no wrapper it serves forever: THE reported hang"
else
    bad "old binary exited rc=$rc after ${elapsed}s (expected the 124 serve-mode hang)"
fi

note "2) NEW binary — unknown subcommand fails fast (no daemon spawn)"
nsv sh -c "timeout 6 $NEW totally-bogus-cmd >/tmp/new-bogus.out 2>&1"; rc=$?
if [[ $rc -eq 2 ]] && grep -q "unknown command" /tmp/new-bogus.out; then
    good "unknown subcommand exits 2 instantly with usage (fall-through closed)"
else
    bad "unknown subcommand rc=$rc out=$(cat /tmp/new-bogus.out)"
fi

note "3) NEW binary — detect before install fails honestly"
nsv sh -c "timeout 8 $NEW firewall detect >/tmp/new-detect0.out 2>&1"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "not installed" /tmp/new-detect0.out; then
    good "detect without panel.json: clear 'not installed' error, exit 1"
else
    bad "pre-install detect rc=$rc out=$(cat /tmp/new-detect0.out)"
fi

note "4) bootstrap panel.json (serve once, then stop)"
nsv sh -c "$NEW >/tmp/serve.out 2>&1 & echo \$! > /tmp/serve.pid; sleep 2; kill \$(cat /tmp/serve.pid) 2>/dev/null; wait 2>/dev/null; test -f $GRE_PANEL_DIR/panel.json && echo BOOTSTRAPPED"
grep -q BOOTSTRAPPED /tmp/serve.out 2>/dev/null
nsv sh -c "test -f $GRE_PANEL_DIR/panel.json" && good "panel.json created" || bad "panel.json missing after bootstrap"

note "5) detect (backend must be iptables)"
nsv sh -c "timeout 8 $NEW firewall detect >/tmp/detect.json 2>&1"; rc=$?
grep -q '"backend": "iptables"' /tmp/detect.json && good "detect: iptables backend" || bad "detect out=$(cat /tmp/detect.json)"

note "6) plan (dry-run) with installer owner — must NOT mutate"
nsv sh -c "timeout 20 $NEW firewall plan --owner service:quantum-controller --add 443/tcp --note installer >/tmp/plan.json 2>&1"; rc=$?
grep -q "\"dry_run\": true" /tmp/plan.json && grep -q '"planned_cmds"' /tmp/plan.json \
    && good "plan: dry-run JSON with planned commands" || bad "plan out=$(cat /tmp/plan.json)"
nsv iptables -S QUANTUM_FW >/dev/null 2>&1 && present=$(nsv iptables -S QUANTUM_FW | grep -c "dport 443") || present=0
[[ "$present" == "0" ]] && good "plan mutated nothing (no dport 443 rule)" || bad "plan created $present rules"

note "7) apply --yes with installer owner"
nsv sh -c "timeout 30 $NEW firewall apply --yes --owner service:quantum-controller --add 443/tcp --note installer >/tmp/apply.json 2>&1"; rc=$?
nsv iptables -S QUANTUM_FW 2>/dev/null | grep -q -- "--dport 443" && good "apply: rule present in the owned QUANTUM_FW chain" || bad "apply: rule missing ($(nsv iptables -S QUANTUM_FW 2>&1))"
nsv iptables -S INPUT 2>/dev/null | grep -q -- "--dport 22" && good "apply: unrelated admin rule preserved" || bad "apply: admin rule lost"
nsv sh -c "test -s $GRE_PANEL_DIR/firewall_audit.jsonl" && good "apply: audited (firewall_audit.jsonl non-empty)" || bad "apply: no audit entry"

note "8) teardown --yes removes only the installer-owned rule"
nsv sh -c "timeout 30 $NEW firewall teardown --owner service:quantum-controller --yes >/tmp/teardown.json 2>&1"; rc=$?
left=$(nsv iptables -S QUANTUM_FW 2>/dev/null | grep -c "dport 443")
[[ "$rc" == "0" && "$left" == "0" ]] && good "teardown: owner rule removed (rc=0, 0 left)" || bad "teardown rc=$rc left=$left out=$(cat /tmp/teardown.json)"
nsv iptables -S INPUT 2>/dev/null | grep -q -- "--dport 22" && good "teardown: admin rule still preserved" || bad "teardown: admin rule lost"

ip netns del "$NS" 2>/dev/null || true
echo "==================================="
if [[ $fails -eq 0 ]]; then echo "FIREWALL ACCEPTANCE PASS"; else echo "FIREWALL ACCEPTANCE FAILED ($fails)"; exit 1; fi
