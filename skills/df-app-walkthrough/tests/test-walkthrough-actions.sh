#!/usr/bin/env bash
# The parts of df-app-walkthrough that DECIDE: the action vocabulary and the auth/cursor
# session helpers. Needs node and nothing else — no browser, no network, no app, no TTS.
#
# ⛔ WHY NODE-ONLY MATTERS. A suite that needed Chromium would not run in the gate, and a
# check that does not run is the defect this repo keeps finding. Everything here is driven
# through `tests/lib/stub-page.mjs`, which records calls in order; what a real browser
# would add on top is listed in `tests/README.md` as NOT covered, so the gap is declared.
#
# ⚠️ ONE NODE PROCESS PER AUTH MODE, AND A SCRUBBED ENVIRONMENT FOR EACH. `session.mjs`
# reads WT_AUTH at module load, so two modes cannot share a process — the second would run
# under the first one's constant and pass for the wrong reason. `scrub` below also UNSETS
# every WT_*/CLERK_* variable before applying the case's own, because a developer who had
# exported WT_APP for a real recording would otherwise change what the suite measures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/lib"

command -v node >/dev/null 2>&1 || { echo "test-walkthrough-actions: need node"; exit 1; }

TOTAL=0
FAILED=0

# Every variable either module reads. Listed once, scrubbed for every case.
SCRUB=(-u WT_AUTH -u WT_APP -u WT_STORAGE_STATE -u WT_SIGNIN_PATH -u WT_READY_SELECTOR
       -u WT_RESOLVE_TIMEOUT_MS -u CLERK_SECRET_KEY -u CLERK_USER_ID)

# run <label> <script> <argv...> [--env NAME=VALUE ...]
#
# ⚠️ The exit status is read from NODE, not from a pipeline. Piping node through grep
# reports GREP's status — a number that looks like a verdict and measures nothing. That
# mistake cost real time during the #224 review and is deliberately not repeated here.
# And this function must NOT be called inside `( … )`: a subshell would discard TOTAL and
# FAILED, and the suite would report 0 assertions while looking like it ran.
run() {
  local label="$1" script="$2"; shift 2
  local argv=() envs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --env) envs+=("$2"); shift 2 ;;
      *)     argv+=("$1"); shift ;;
    esac
  done
  local out rc n
  out="$(env "${SCRUB[@]}" "${envs[@]}" node "$script" "${argv[@]}" 2>&1)"; rc=$?
  n="$(printf '%s\n' "$out" | grep -Eo '^ASSERTIONS: [0-9]+$' | tail -1 | tr -cd '0-9')"
  : "${n:=0}"
  TOTAL=$((TOTAL + n))
  if [ "$rc" -eq 0 ] && [ "$n" -gt 0 ]; then
    printf '  PASS  %-34s %s assertions\n' "$label" "$n"
  else
    FAILED=$((FAILED + 1))
    printf '  FAIL  %-34s rc=%s assertions=%s\n' "$label" "$rc" "$n"
    printf '%s\n' "$out" | sed 's/^/        | /'
  fi
}

# The four CLERK_* values below are OBVIOUS NON-SECRETS. `fetch` is stubbed inside the
# case, so nothing leaves the machine; they exist only to get past the presence check.
CK=(--env CLERK_SECRET_KEY=not-a-real-key --env CLERK_USER_ID=not-a-real-user
    --env WT_AUTH=clerk-ticket --env WT_APP=https://app.invalid)

echo "=== df-app-walkthrough — action vocabulary ==="
run "runAction (whole vocabulary)" "$LIB/case-actions.mjs"

echo
echo "=== df-app-walkthrough — session: auth modes ==="
run "contextOptions: default"       "$LIB/case-session.mjs" ctx-none
run "contextOptions: storage, none" "$LIB/case-session.mjs" ctx-storage-missing --env WT_AUTH=storage-state
run "contextOptions: storage, path" "$LIB/case-session.mjs" ctx-storage-ok \
    --env WT_AUTH=storage-state --env WT_STORAGE_STATE=/tmp/does-not-need-to-exist.json
run "contextOptions: clerk"         "$LIB/case-session.mjs" ctx-clerk --env WT_AUTH=clerk-ticket

run "signIn: none"                  "$LIB/case-session.mjs" signin-none \
    --env WT_AUTH=none --env WT_APP=https://app.invalid/
run "signIn: none, no app"          "$LIB/case-session.mjs" signin-none-noapp --env WT_AUTH=none
run "signIn: unknown mode refuses"  "$LIB/case-session.mjs" signin-unknown --env WT_AUTH=totally-made-up
run "signIn: clerk, no credentials" "$LIB/case-session.mjs" signin-clerk-nokey --env WT_AUTH=clerk-ticket

run "signIn: clerk, HTTP error"        "$LIB/case-session.mjs" signin-clerk-http    "${CK[@]}"
run "signIn: clerk, 200 with no token" "$LIB/case-session.mjs" signin-clerk-notoken "${CK[@]}"
run "signIn: clerk, lands first try"   "$LIB/case-session.mjs" signin-clerk-ok      "${CK[@]}"
run "signIn: clerk, fresh ticket x3"   "$LIB/case-session.mjs" signin-clerk-retry   "${CK[@]}"
run "signIn: clerk, custom path"       "$LIB/case-session.mjs" signin-clerk-path    "${CK[@]}" \
    --env WT_SIGNIN_PATH=/enter

echo
echo "=== df-app-walkthrough — the drawn cursor ==="
run "CURSOR_INIT_SCRIPT runs"       "$LIB/case-session.mjs" cursor
run "glideTo / showClick"           "$LIB/case-session.mjs" glide

echo
printf 'cases failed: %s\n' "$FAILED"
printf 'ASSERTIONS: %s\n' "$TOTAL"
[ "$FAILED" -eq 0 ] || exit 1
