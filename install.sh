#!/usr/bin/env bash
# Quantum private-repository installer. Export GRE_GITHUB_TOKEN before fetching
# this script, or enter a token when running an already-downloaded copy.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    printf 'Error: Please run as root (sudo).\n' >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PRIMARY="https://raw.githubusercontent.com/Dark-modem/quantum/main/quantum.sh"
API_SOURCE="https://api.github.com/repos/Dark-modem/quantum/contents/quantum.sh?ref=main"
TOKEN_FILE="${GRE_PANEL_DIR:-/etc/gre-panel}/github-token"
_install_token="${GRE_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"

installer_token() {
    if [[ -z "$_install_token" && -f "$TOKEN_FILE" ]]; then
        _install_token=$(tr -d '\r\n' < "$TOKEN_FILE")
    fi
    local token_tty
    if [[ -z "$_install_token" ]] && { exec {token_tty}<>/dev/tty; } 2>/dev/null; then
        printf 'Private repository: enter a Quantum GitHub read token (hidden): ' >&"$token_tty"
        IFS= read -r -s _install_token <&"$token_tty" || true
        printf '\n' >&"$token_tty"
        exec {token_tty}>&-
    fi
    if [[ -z "$_install_token" ]]; then
        printf 'Error: Quantum is private. No GitHub token was provided.\n' >&2
        printf 'Export GRE_GITHUB_TOKEN, or save it at %s (mode 600).\n' "$TOKEN_FILE" >&2
        return 1
    fi
    if [[ ! "$_install_token" =~ ^[A-Za-z0-9_]+$ ]]; then
        printf 'Error: token contains whitespace or invalid characters; paste the token only.\n' >&2
        return 1
    fi
    export GRE_GITHUB_TOKEN="$_install_token"
}

url_host() { local h="${1#*://}"; printf '%s\n' "${h%%/*}"; }

# Authentication is restricted to the exact Quantum raw/API endpoints. Curl
# drops credentials on cross-host redirects; no --location-trusted is used.
installer_download() {
    local U="$1" F="$2" host code rc=0
    local headers=()
    host=$(url_host "$U")
    case "$U" in
        https://raw.githubusercontent.com/Dark-modem/quantum/*|https://api.github.com/repos/Dark-modem/quantum/*)
            if [[ -n "${_install_token:-}" ]]; then
                headers=(--config -)
            fi
            ;;
    esac
    if [[ "$U" == https://api.github.com/repos/Dark-modem/quantum/contents/* ]]; then
        headers+=(-H 'Accept: application/vnd.github.raw+json')
    fi
    if [[ "${headers[0]:-}" == --config ]]; then
        code=$(printf 'header = "Authorization: Bearer %s"\n' "$_install_token" |
            curl -fsSL "${headers[@]}" --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 60 \
                -w '%{http_code}' "$U" -o "$F" 2> "$TMP/curl-error") || rc=$?
    else
        code=$(curl -fsSL "${headers[@]}" --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 60 \
            -w '%{http_code}' "$U" -o "$F" 2> "$TMP/curl-error") || rc=$?
    fi
    if [[ "$rc" -eq 0 ]]; then return 0; fi
    case "$code" in
        401) printf 'Error: %s returned 401: invalid or expired GitHub token.\n' "$host" >&2 ;;
        403) printf 'Error: %s returned 403: check token permissions, approval and API rate limits.\n' "$host" >&2 ;;
        404) printf 'Error: %s returned 404: select Dark-modem/quantum in Repository access and grant Contents: Read-only.\n' "$host" >&2 ;;
        000) printf 'Error: cannot reach %s (DNS, connection or TLS failure; curl exit %s).\n' "$host" "$rc" >&2 ;;
        *) printf 'Error: download from %s failed (HTTP %s, curl exit %s).\n' "$host" "$code" "$rc" >&2 ;;
    esac
    return 1
}

# Canonical GitHub TLS or a pinned SHA256 is authoritative. Mirror quorum is
# retained only for explicit public/test URL overrides, never private downloads.
fetch_verified() {
    local out="$1" i=0 U f sum host
    local -A seen_sum=()
    for U in "${URLS[@]}"; do
        i=$((i + 1)); f="$TMP/cand.$i"
        installer_download "$U" "$f" || continue
        if [[ ! -s "$f" ]] || ! bash -n "$f" 2>/dev/null; then
            printf 'Error: downloaded manager script is empty or has invalid shell syntax.\n' >&2
            continue
        fi
        sum=$(sha256sum "$f" | cut -d' ' -f1)
        host=$(url_host "$U")
        if [[ -n "${QUANTUM_SHA256:-}" ]]; then
            if [[ "${QUANTUM_SHA256,,}" == "$sum" ]]; then cp "$f" "$out"; printf '%s\n' "$sum"; return 0; fi
            printf 'Error: %s supplied a script with an unexpected SHA256.\n' "$host" >&2
            continue
        fi
        if [[ "$U" == "$PRIMARY" || "$U" == "${API_SOURCE:-}" ]]; then
            cp "$f" "$out"; printf '%s\n' "$sum"; return 0
        fi
        if [[ -n "${_install_token:-}" ]]; then continue; fi
        if [[ -n "${seen_sum[$sum]:-}" && "${seen_sum[$sum]}" != "$host" ]]; then
            cp "$f" "$out"; printf '%s\n' "$sum"; return 0
        fi
        seen_sum[$sum]="$host"
        if [[ "${QUANTUM_ALLOW_UNVERIFIED:-0}" == 1 ]]; then
            cp "$f" "$out"; printf '%s\n' "$sum"; return 0
        fi
    done
    return 1
}

clear 2>/dev/null || true
printf '\n  Q U A N T U M\n  Reverse Tunnel & Web Panel Installer\n\n'

if [[ -n "${QUANTUM_INSTALL_URLS:-}" ]]; then
    read -r -a URLS <<< "$QUANTUM_INSTALL_URLS"
    PRIMARY="${URLS[0]}"
else
    installer_token || exit 1
    URLS=("$PRIMARY" "$API_SOURCE")
fi
printf '[*] Downloading and verifying the Quantum manager...\n'
if ! SCRIPT_SHA=$(fetch_verified "$TMP/quantum.sh"); then
    printf 'Error: no verified manager script obtained; nothing was installed.\n' >&2
    printf 'Check the error above. Private releases cannot be fetched through public mirrors.\n' >&2
    exit 1
fi
printf '[OK] quantum.sh SHA256: %s\n' "$SCRIPT_SHA"
if [[ "${1:-}" == --check ]]; then
    printf '[OK] Private download and script validation succeeded (check-only, no installation).\n'
    exit 0
fi

if [[ -n "${_install_token:-}" ]]; then
    mkdir -p "$(dirname "$TOKEN_FILE")"
    if [[ -L "$TOKEN_FILE" ]]; then printf 'Error: token file must not be a symlink.\n' >&2; exit 1; fi
    token_tmp=$(mktemp "$(dirname "$TOKEN_FILE")/.github-token.XXXXXX")
    chmod 600 "$token_tmp"
    printf '%s\n' "$_install_token" > "$token_tmp"
    mv -f "$token_tmp" "$TOKEN_FILE"
fi

mkdir -p /usr/local/bin
install -m 0755 "$TMP/quantum.sh" /usr/local/bin/quantum.sh.new
mv -f /usr/local/bin/quantum.sh.new /usr/local/bin/quantum.sh
ln -sfn /usr/local/bin/quantum.sh /usr/local/bin/quantum
ln -sfn /usr/local/bin/quantum.sh /usr/local/bin/gre.sh
bash /usr/local/bin/quantum "$@"
