#!/usr/bin/env bash
# lib/common.sh — shared plumbing: logging, config, run identity.
# Part of tests/matrix-agent-lab. Lab-only; never touches production.

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_PREFIX="qmx"                      # every object we create starts with this
RUNID=""                              # set by lab_new_runid()
RUN_DIR=""

LAB_CONF="${LAB_CONF:-$LAB_ROOT/lab.conf}"

_log_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_info()  { printf '[%s] INFO  %s\n' "$(_log_ts)" "$*"; }
log_warn()  { printf '[%s] WARN  %s\n' "$(_log_ts)" "$*" >&2; }
log_error() { printf '[%s] ERROR %s\n' "$(_log_ts)" "$*" >&2; }
log_die()   { log_error "$*"; exit 1; }

# Unique 8-hex run id — guarantees all lab object names are unique.
lab_new_runid() {
    RUNID="$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
    [ -n "$RUNID" ] || log_die "cannot generate run id"
}

# Full lab name for a component, e.g. n "iran" -> qmx1a2b3c4d_iran
lab_name() { printf '%s%s_%s' "$LAB_PREFIX" "$RUNID" "$1"; }

lab_load_conf() {
    [ -f "$LAB_CONF" ] || log_die "config not found: $LAB_CONF (copy lab.conf.example to lab.conf)"
    # shellcheck disable=SC1090
    . "$LAB_CONF"
    : "${ENGINE_MODE:=real}"
    : "${BILLING_MODEL:=interface-counter}"
    : "${BILLING_IFACE_PHYS:=wan0 tlink}"
    : "${BILLING_IFACE_TUNNEL:=matrix}"
    : "${COUNTER_BACKEND:=auto}"
    : "${PAYLOAD_MIB:=100}"
    : "${LATENCY_WINDOW_S:=60}"
    : "${THROUGHPUT_SUBWINDOWS:=5}"
    : "${BLACKOUT_S:=8}"
    : "${MATRIX_PORT:=2097}"
    : "${PAYLOAD_PORT:=8080}"
    : "${IRAN_TUN_IP:=172.16.99.1}"
    : "${KHAREJ_TUN_IP:=172.16.99.2}"
    : "${IRAN_WAN_IP:=10.100.0.1}"
    : "${CLIENT_WAN_IP:=10.100.0.2}"
    : "${IRAN_TLINK_IP:=10.200.0.1}"
    : "${KHAREJ_TLINK_IP:=10.200.0.2}"
}

# Refuse anything but root — every lab operation needs CAP_NET_ADMIN.
require_root() {
    [ "$(id -u)" = "0" ] || log_die "must run as root (sudo). Refusing to continue."
}

# Result helpers used by suites: each test records a status.
# TESTS_JSON is an open JSON array the suite appends to via python.
declare -a TEST_RESULTS=()

test_result() {
    # test_result <id> <status:pass|fail|unknown|skipped> <summary> [<detail-json>]
    local id="$1" status="$2" summary="$3" detail="${4:-}"
    TEST_RESULTS+=("$(printf '{"id":"%s","status":"%s","summary":"%s"%s}' \
        "$id" "$status" "$(json_escape "$summary")" \
        "${detail:+,\"detail\":$detail}")")
}

json_escape() {
    # Minimal JSON string escaper for known-safe lab strings.
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

# Integer/float guard for ratios: never emit a bogus number.
ratio_or_unknown() {
    # $1 numerator $2 denominator -> ratio as string, or "UNKNOWN"
    awk -v n="$1" -v d="$2" 'BEGIN{
        if (d+0 <= 0 || n == "" || n !~ /^[0-9.]+$/ || d !~ /^[0-9.]+$/) print "UNKNOWN";
        else printf "%.4f", n/d }'
}
