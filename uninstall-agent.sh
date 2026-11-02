#!/usr/bin/env bash
###############################################################################
# uninstall-agent.sh — Quantum endpoint agent removal
#
# Removes the Quantum endpoint Agent (gre-agent) from this endpoint.
#
#   sudo bash uninstall-agent.sh [--purge] [--yes]
#
# Default (without --purge): stops and disables gre-agent.service, removes the
# unit and keeps the enrollment (/etc/gre-panel/agent.json), the binary and
# the backups — reinstalling later needs no new enrollment token.
#
# --purge additionally removes the enrollment identity, the agent state, the
# installer metadata and the backups, and removes the binary only when no
# gre-panel.service (controller/panel) exists on this host.
#
# Never touched, ever: quantum-matrix* units (Matrix tunnels keep running),
# xray, tinc, firewall rules, SSH configuration, Docker, PasarGuard.
#
# To also revoke the endpoint on the controller (invalidating its identity),
# revoke the agent in the controller UI — the endpoint has no CLI for that.
###############################################################################
set -euo pipefail

###############################################################################
# Constants (must mirror install-agent.sh)
###############################################################################
SCRIPT_NAME="uninstall-agent.sh"
BIN="/usr/local/bin/gre-panel"
UNIT_DIR="/etc/systemd/system"
UNIT="gre-agent.service"
UNIT_NAME="gre-agent"
PANEL_DIR="/etc/gre-panel"
AGENT_DIR="$PANEL_DIR/agent"
IDENTITY="$PANEL_DIR/agent.json"
STATE="$PANEL_DIR/agent-state.json"
BACKUP_DIR="/var/backups/quantum-agent"

PHASE="startup"
PURGE=0
ASSUME_YES=0
REMOVED_UNIT=0

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_OFF=""
fi

info()  { printf '%s[%s]%s %s\n'  "$C_BLUE"  "$PHASE" "$C_OFF" "$*"; }
ok()    { printf '%s[ok]%s %s\n'         "$C_GREEN" "$C_OFF" "$*"; }
warn()  { printf '%s[warn]%s %s\n'       "$C_YELLOW" "$C_OFF" "$*"; }
err()   { printf '%s[error]%s %s\n'      "$C_RED" "$C_OFF" "$*" >&2; }
die()   { err "$*"; exit 1; }
phase() { PHASE="$1"; printf '\n%s==> %s%s\n' "$C_CYAN" "$*" "$C_OFF"; }

on_err() {
    printf '\n%s[error]%s uninstall-agent.sh FAILED (exit %s) near line %s, during phase: %s\n' \
        "$C_RED" "$C_OFF" "$1" "$2" "$PHASE" >&2
    printf 'The agent unit may be partially removed; re-running this script is safe.\n' >&2
}
trap 'on_err "$?" "$LINENO"' ERR

usage() {
    cat <<'USAGE'
uninstall-agent.sh — Quantum endpoint agent removal

Usage:
  sudo bash uninstall-agent.sh [--purge] [--yes]

Options:
  --purge   Also remove the enrollment identity (/etc/gre-panel/agent.json),
            the agent state, the installer metadata, the backups and — when
            no gre-panel.service exists — the binary itself.
  --yes     Never prompt (automation mode).

Without --purge the enrollment is kept, so a later reinstall needs no new
enrollment token. Matrix tunnels (quantum-matrix*) are never touched.
USAGE
    exit 0
}

have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
    local reply
    [[ $ASSUME_YES -eq 1 ]] && return 0
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

matrix_units_snapshot() {
    systemctl list-units --all 'quantum-matrix*' --no-legend 2>/dev/null \
        | awk '{print $1, $3}' | sort || true
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge)  PURGE=1; shift ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            --help|-h) usage ;;
            *) err "unknown option: $1"; usage ;;
        esac
    done
}

###############################################################################
# Phase: service removal
###############################################################################
remove_service() {
    if ! have systemctl; then
        warn "systemctl not available; removing the unit file only."
    elif systemctl list-unit-files --no-legend "$UNIT" 2>/dev/null | grep -q .; then
        if systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
            info "Stopping $UNIT_NAME (quantum-matrix units are NOT touched)."
        fi
        systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/$UNIT"
        systemctl daemon-reload
        systemctl reset-failed "$UNIT_NAME" 2>/dev/null || true
        REMOVED_UNIT=1
        ok "$UNIT removed and disabled."
    else
        ok "$UNIT not installed; nothing to remove."
    fi
}

###############################################################################
# Phase: optional purge
###############################################################################
do_purge() {
    local removed=0
    for f in "$IDENTITY" "$STATE"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            ok "Removed $f."
            removed=1
        fi
    done
    if [[ -d "$AGENT_DIR" ]]; then
        rm -rf "$AGENT_DIR"
        ok "Removed $AGENT_DIR."
        removed=1
    fi
    if [[ -d "$BACKUP_DIR" ]]; then
        rm -rf "$BACKUP_DIR"
        ok "Removed $BACKUP_DIR."
        removed=1
    fi
    if [[ -f "$BIN" ]]; then
        if systemctl list-unit-files --no-legend gre-panel.service 2>/dev/null | grep -q .; then
            warn "gre-panel.service exists on this host; keeping $BIN (it belongs to the controller/panel)."
        else
            rm -f "$BIN"
            ok "Removed $BIN."
            removed=1
        fi
    fi
    [[ $removed -eq 1 ]] || info "Nothing left to purge."
}

show_summary() {
    printf '\n%s==================================================%s\n' "$C_BOLD" "$C_OFF"
    printf '%s[OK]%s Quantum endpoint agent removed.\n' "$C_GREEN" "$C_OFF"
    if [[ $PURGE -eq 1 ]]; then
        printf 'Purge:        enrollment, state, metadata and backups removed.\n'
    else
        printf 'Kept:         enrollment identity and binary (reinstall needs no new token).\n'
        printf 'Full removal: sudo bash %s --purge\n' "$SCRIPT_NAME"
    fi
    if systemctl list-units --all 'quantum-matrix*' --no-legend 2>/dev/null | grep -q .; then
        printf 'Matrix:       quantum-matrix units left untouched (%s).\n' \
            "$(systemctl is-active quantum-matrix.service 2>/dev/null || echo 'see systemctl')" 
    fi
    printf 'Revoke:       revoke this agent in the controller UI to invalidate its identity.\n'
    printf 'Reinstall:    sudo bash install-agent.sh --server <url> --token <new-token>\n'
    printf '%s==================================================%s\n' "$C_BOLD" "$C_OFF"
}

main() {
    parse_args "$@"
    [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."

    phase "prerequisites"
    local before
    before="$(matrix_units_snapshot)"

    if [[ $PURGE -eq 1 ]]; then
        if [[ -f "$IDENTITY" || -d "$AGENT_DIR" || -f "$BIN" ]]; then
            confirm "Purge will permanently remove the enrollment identity, agent state, metadata, backups and (if no panel is installed) the binary. Continue? "
        fi
    fi

    phase "service removal"
    remove_service

    if [[ $PURGE -eq 1 ]]; then
        phase "purge"
        do_purge
    else
        if [[ $REMOVED_UNIT -eq 1 ]]; then
            info "Kept: $IDENTITY, $BIN, $BACKUP_DIR (reinstall needs no new enrollment token)."
        fi
    fi

    # Matrix independence check: uninstalling the agent must not have changed
    # any quantum-matrix unit state.
    local after
    after="$(matrix_units_snapshot)"
    if [[ "$after" != "$before" ]]; then
        warn "quantum-matrix unit states changed during uninstallation (unexpected):"
        diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
    else
        ok "quantum-matrix units untouched."
    fi

    show_summary
}

main "$@"
