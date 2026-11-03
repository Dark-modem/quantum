# Session 4 — Linux CI Closure & Final Security Gate

**Branch:** `sec4/linux-ci-closure` (base: main `e1d1f85`). All runs on a real Linux
environment: **WSL Ubuntu-24.04, Go 1.23.4 linux/amd64, gcc 13.3 (CGO for `-race`)**.
No live server touched.

## Mission A — Linux race failures: CLOSED

`go test -race -count=5 ./...` (final, after fixes): **ok 458.348s, RC=0,
0 DATA RACE warnings, 0 test failures.** Also green on Linux: `go vet ./...`,
`go test ./...` (1031 PASS / 19 SKIP / 0 FAIL), hermetic installer suite
(21/21, incl. `test_controller_product.sh`).

### Failure ledger (every Linux failure found, root-caused and fixed)

| # | Finding | Class | Root cause | Fix commit | Regression |
|---|---|---|---|---|---|
| R1 | `TestI18nSourceIsEnglish` — Persian text at `index.html:1372,1374` | production source defect | the new firewall/netopt nav badges hardcoded `پلن`; Persian must live only in `i18n-fa.js` | `6669489` | the existing i18n source test |
| R2 | `TestAgentHubHappyPath` — "timed out waiting for counter reset rate" | harness defect | the counter-reset rate lives in session memory until the next persist; with `agentPersistEvery=30ms` hb3's persist can be suppressed and no later heartbeat flushes it | `6669489` | hb4 continues the reset window deterministically |
| R3 | `SSH_LISTEN_TRIES=6` set but never read (QA claim not true) | harness defect (reliability) | `ssh_verify_listening` had no polling loop | `fe9bf07` | hermetic retry test (counting `ss` stub) |
| R4 | **32 DATA RACE warnings** under `-race -count=1` | test-seam races | lab cleanups restored plain func/pointer globals while hub sessions, heartbeat loops, ack observers, delete teardowns and provisioning goroutines still read them (production writes these once at startup — no production pair) | `ca26569` | full `-race` suite |
| R5 | races persisted after R4's drain work | test-seam (silent patch failure) | the readLoop spawn conversion silently failed to match (`str.replace` without assert) — `go s.handleDesired(d)` stayed unwrapped | `f96a268` | same |
| R6 | `-count=5`: `TestBagherAPIEndpoints` expected 400 got 200 | test-isolation | TestMain shares one configDir across counts; a saved `sshfwd.json` leaked | `39cdb7f` | `withTempConfig` isolation |
| R7 | `-count=5`: `TestHandleUpdateRefusesNotNewer` hit the real mirror (429) | test-isolation + network dependence | the 10-minute in-memory release cache leaked across counts; stubbed fetcher not authoritative | `39cdb7f` | `dropReleaseCache` at test start |
| R8 | `-count=5`: `TestAgentHubApply` port refusal | test determinism | `freeMeshPort` probes-and-closes; two calls can return the same ephemeral port, which `validateMatrixSettings` correctly refuses | `bb8465c` | re-draw until distinct |

Iteration trail (DATA RACE warnings per full `-race -count=1` Linux run):
32 → 13 (seam holders + WG-tracked teardowns/provisioning) → 3 (hub drain waits) →
2 (agent-ops WG) → **0** (readLoop spawns actually wrapped — `f96a268` was the real
fix; `ca26569`'s spawn conversion had silently failed).

**Classification proof:** every racing pair had the write side inside a test closure
(`newAgentTunnelLab.func*`, `matrixInstanceLab.func3`, `agentLab.func2`,
`withTempConfig.func1`) — production writes these globals exactly once at startup.
No production-vs-production race existed. The WG/holder changes give the race
detector synchronized access without altering production behavior (seams are
set-once in production).

## Mission B — Security re-verification at main (`e1d1f85`)

All content checks CONFIRMED at the current main (grep-verified in source):
SU-1 fail-closed self-update (refusal paths + audited override); SU-2 origin-scoped
downloads + redirect guard; XFF last trusted hop; enrollment hashing/revocation;
hub pre-upgrade auth; firewall/netopt typed ops (requireAuth+CSRF routes, dual
confirm gates, owner tags, dual audit); netopt root enforcement
(`netRequireWritableInstall`) + 0600 journal + `netRestore`; installer SSH fixes and
lib pinning (commit + SHA-256); `QUANTUM_UPDATE_ALLOW_UNSIGNED` absent from every
shell/YAML file (Go source + docs only). Regression suites `TestSec4*`,
`TestUpdateSignatureFailClosed`, `TestAgentUpdateDownloadCredentialScoping`,
`TestAgentHub*`, `TestAgentReg*` all PASS on Linux in the final runs.

## Mission C — Signing-key custody (workflows audited at main + fixes)

- Private material: never in the repository; only the `UPDATE_SIGNING_KEY` Actions
  secret. `update-pub.b64` (public, base64 DER SPKI) is committed and pinned into
  every production build (`-X main.agentUpdatePubKeyPEM`, both architectures).
- **Gap found and fixed (`ed7acea`):** a tag build with the secret unset used to
  `::warning::` and ship unsigned — now the workflow **fails closed** with an
  actionable error. (Dev/branch builds keep working; they are never released.)
- Signatures: per-artifact `openssl pkeyutl -sign -rawin` over the exact released
  files, matching the runtime verifier (Ed25519 over artifact bytes); all `.sig`
  files are uploaded beside the binaries; `checksums.txt` + `provenance.txt` published.
- **Added (`b0c387b`):** `SECURITY.md` now documents generation, custody, the owner's
  independent verification procedure (sha256 → DER → `pkeyutl -verify` per artifact),
  and the rotation/deployment order.

## Handoff to Session 3 (branch `sec4/linux-ci-closure`, in order)

`6669489`, `fe9bf07`, `ca26569`, `f96a268`, `39cdb7f`, `bb8465c`, `ed7acea`,
`b0c387b`, `a3ba96b` — plus the already-merged gate commit `e353fff`.
Merge this branch into `main` and re-tag v1.29.1 from the merge result; the release
build will pin `update-pub.b64` and ship `.sig` files (the workflow now requires the
signing secret).

## NOT VERIFIED (honest)

- GitHub-hosted runner behavior (this was WSL Ubuntu-24.04, Go 1.23.4 — same
  GOOS/GOARCH, real kernel, real gcc; not the exact CI image).
- `gosec`/`govulncheck` runs (advisory, non-blocking in `security.yml`).
- The real-domain installer matrix V1–V11 (needs the owner's FQDN).
