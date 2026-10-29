#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
TMP="$T/work"; mkdir -p "$TMP" "$T/bin"
for fn in installer_token url_host installer_download fetch_verified; do
    awk -v name="$fn" '$0 ~ "^" name "\\(\\) \\{" {p=1} p {print} p && /^}/ {p=0}' "$ROOT/install.sh"
done > "$T/functions.sh"
source "$T/functions.sh"
GOOD=$'#!/bin/bash\necho manager\n'
printf '%s' "$GOOD" > "$T/manager.sh"
TOKEN_FILE="$T/saved-token"
API_SOURCE='https://api.github.com/repos/Dark-modem/quantum/contents/hashem.sh?ref=main'
PRIMARY='https://raw.githubusercontent.com/Dark-modem/quantum/main/hashem.sh'
export TEST_DIR="$T"
cat > "$T/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -eu
out=''; url=''; conf=''
while (($#)); do
 case "$1" in
  --config) conf="$2"; shift 2 ;;
  -o) out="$2"; shift 2 ;;
  https://*) url="$1"; shift ;;
  *) shift ;;
 esac
done
header=''; if [[ "$conf" == '-' ]]; then header=$(cat); fi
printf '%s|%s\n' "$url" "$header" >> "$TEST_DIR/requests"
if [[ "$url" == *raw.githubusercontent.com* && "${TEST_FAIL_RAW:-0}" == 1 ]]; then printf 000; exit 6; fi
if [[ "${TEST_HTTP_ERROR:-0}" != 0 ]]; then printf '%s' "$TEST_HTTP_ERROR"; exit 22; fi
cp "$TEST_DIR/manager.sh" "$out"
printf 200
CURL
chmod +x "$T/bin/curl"
PATH="$T/bin:$PATH"

_install_token='testtoken_12345678901234567890'
installer_download "$PRIMARY" "$T/result"; cmp "$T/result" "$T/manager.sh"
installer_download 'https://mirror.ghproxy.com/https://raw.githubusercontent.com/Dark-modem/quantum/main/hashem.sh' "$T/result"
installer_download 'https://example.org/script.sh' "$T/result"
[[ $(grep -c 'Authorization: Bearer' "$T/requests") == 1 ]]
[[ $(grep 'https://example.org' "$T/requests") != *Authorization* ]]
[[ $(grep 'https://mirror.ghproxy.com' "$T/requests") != *Authorization* ]]
echo 'PASS: token is sent only to canonical Quantum endpoints'

URLS=("$PRIMARY" "$API_SOURCE")
export TEST_FAIL_RAW=1
SHA=$(fetch_verified "$T/result" 2> "$T/log")
[[ "$SHA" == "$(sha256sum "$T/manager.sh" | cut -d' ' -f1)" ]]
grep -q 'api.github.com/repos/Dark-modem/quantum/contents/' "$T/requests"
echo 'PASS: API raw fallback after canonical raw DNS failure'
unset TEST_FAIL_RAW

for code in 401 403 404 000; do
 export TEST_HTTP_ERROR="$code"
 if installer_download "$PRIMARY" "$T/result" 2> "$T/log"; then exit 1; fi
 case "$code" in
  401) grep -q 'invalid or expired' "$T/log" ;;
  403) grep -q 'permissions' "$T/log" ;;
  404) grep -q 'Repository access' "$T/log" ;;
  000) grep -q 'cannot reach' "$T/log" ;;
 esac
 ! grep -q "$_install_token" "$T/log"
done
unset TEST_HTTP_ERROR
echo 'PASS: actionable errors for authentication and connectivity'

printf 'saved_token_12345678901234567890\n' > "$TOKEN_FILE"
_install_token=''; installer_token
[[ "$GRE_GITHUB_TOKEN" == saved_token_12345678901234567890 ]]
echo 'PASS: saved token is read and exported to manager'
TOKEN_FILE="$T/missing-token"
if setsid bash -c 'source "$1"; TOKEN_FILE="$2"; _install_token=""; installer_token' _ "$T/functions.sh" "$TOKEN_FILE" 2> "$T/log"; then exit 1; fi
grep -q 'No GitHub token was provided' "$T/log"
echo 'PASS: noninteractive missing-token failure is explicit'
_install_token=$'github_pat_bad\nvalue'
if installer_token 2> "$T/log"; then exit 1; fi
echo 'PASS: newline/header injection is rejected'

_install_token='testtoken_12345678901234567890'; export GRE_GITHUB_TOKEN="$_install_token"
# The check-only path must stop before token persistence or manager execution.
# Simulate root only in the isolated test copy; the production installer keeps
# its root requirement. GitHub's runner account is intentionally unprivileged.
sed 's/^if \[\[ $EUID -ne 0 \]\]; then$/if false; then/' "$ROOT/install.sh" > "$T/install-check.sh"
bash "$T/install-check.sh" --check > "$T/full-log" 2>&1
grep -q 'check-only, no installation' "$T/full-log"
echo 'PASS: full installer --check validates download without touching installation'

# Run the complete installer in a temporary filesystem with a harmless manager.
# Only its /usr/local/bin destination is redirected; production files stay untouched.
mkdir -p "$T/install-root/bin" "$T/token-dir"
sed "s#/usr/local/bin#$T/install-root/bin#g" "$T/install-check.sh" > "$T/install-full.sh"
printf '#!/bin/bash\nset -eu\ntest -n "${GRE_GITHUB_TOKEN:-}"\nprintf manager-ran > "$TEST_DIR/manager-ran"\n' > "$T/manager.sh"
GRE_PANEL_DIR="$T/token-dir" bash "$T/install-full.sh" > "$T/full-log" 2>&1
[[ -f "$T/manager-ran" ]]
[[ -L "$T/install-root/bin/hashem" && -L "$T/install-root/bin/gre.sh" ]]
cmp "$T/manager.sh" "$T/install-root/bin/hashem.sh"
[[ $(stat -c %a "$T/token-dir/github-token") == 600 ]]
[[ $(cat "$T/token-dir/github-token") == "$_install_token" ]]
echo 'PASS: complete installer persists token 600, creates launchers and runs the manager'
