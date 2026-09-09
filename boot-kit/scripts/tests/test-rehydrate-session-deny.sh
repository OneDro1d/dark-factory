#!/usr/bin/env bash
# test-rehydrate-session-deny.sh — the restore leg must wire the SESSION deny list too, not
# only hooks.
#
# ⛔ WHY THIS EXISTS. mcp-profile-config.py --session-deny can DERIVE every estate another
# record in the kit names that this one does not; wire-settings.py --deny-file can MERGE that
# derivation into the live settings. Until rehydrate.sh's restore leg calls both, in order, a
# freshly restored machine has the derivation available and nothing that ever runs it — the
# exact "declared, installed, not wired" shape section 4 already fixed for hooks, one key over.
#
# THE ASSERTION IS THE LIVE FILE, NOT THE MESSAGE, same discipline as
# test-rehydrate-wires-hooks.sh: a change that printed the 4b header and denied nothing would
# pass a message-only check and fail this one.
#
# Usage: bash boot-kit/scripts/tests/test-rehydrate-session-deny.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
RH="${REHYDRATE:-$SCRIPTS/rehydrate.sh}"
[ -f "$RH" ] || { echo "missing $RH"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rhsd.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A kit shaped like SD1 in test-mcp-profile-config.sh: a ROOT loom.lock.json declaring two
# estates (a: hubs, b: connector) and an instances/x/loom.lock.json declaring only estate a.
# rehydrate is run with $ROOT = this kit directory, so $ROOT/loom.lock.json (estate a+b, the
# "root" record) is what rehydrate's OWN sections 1-3 use — and it is deliberately the FULLER
# record, so RD2 (no LOOM_LOCK) exercises "the resolved record is the root itself" (SD2's
# shape: own already covers everything, nothing to deny) while RD1 (LOOM_LOCK=instances/x/…)
# exercises the instance whose own record is the LIMITED one (SD1's shape: the root names an
# estate x does not, denied).
kit() {
  K="$TMP/$1"
  mkdir -p "$K/boot-kit/config" "$K/live" "$K/vendor" "$K/instances/x"
  jq -n '{vendorDir:"vendor", upstreams:{}, install:{skills:[],skillSources:{},hooks:[],hookSources:{}},
          mcp:{profiles:{
            a:{kind:"hubs", servers:["hub-a","hub-a-dev"]},
            b:{kind:"connector", servers:["claude.ai Estate B"]}}}}' \
    > "$K/loom.lock.json"
  jq -n '{mcp:{profiles:{a:{kind:"hubs", servers:["hub-a","hub-a-dev"]}}}}' \
    > "$K/instances/x/loom.lock.json"
  cat > "$K/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": {} }
JSON
}
# ⚠️ `env`, not a bare `VAR=val $extra bash …`. An assignment-prefix from a PARAMETER
# EXPANSION (${2:-}) is never recognised as one by bash -- only a literal NAME=value token in
# the source is -- so an expanded "LOOM_LOCK=…" word is instead executed as a command and
# fails with "No such file or directory". `env` takes the same word as plain argument data and
# applies it as an environment assignment itself, which is a real command doing real parsing.
run() { ( cd "$TMP/$1" && env LOOM_LIVE="$TMP/$1/live" ${2:-} bash "$RH" --offline 2>&1 ); }

echo "=== RD1: LOOM_LOCK=instances/x/… -- the root names an estate x does not, denied ==="
kit rd1
O="$(run rd1 "LOOM_LOCK=instances/x/loom.lock.json")"
contains "RD1: the 4b header is printed" "4b. session deny list" "$O"
contains "RD1: transcript names the denied estate" "claude.ai Estate B" "$O"
if [ -f "$TMP/rd1/live/settings.json" ]; then ok "RD1: settings.json exists"
else bad "RD1: settings.json exists" "nothing written"; fi
contains "RD1: the live settings actually carry the deny entry" "claude.ai Estate B" \
         "$(cat "$TMP/rd1/live/settings.json" 2>/dev/null)"

echo "=== RD2: the root record itself (no LOOM_LOCK) -- nothing to deny ==="
kit rd2
O="$(run rd2)"
contains "RD2: says nothing to deny" "nothing to deny" "$O"
absent   "RD2: no deny entry is wired" "deniedMcpServers" "$(cat "$TMP/rd2/live/settings.json" 2>/dev/null)"

echo "=== RD3: --dry-run -- header printed, live file untouched ==="
kit rd3
O="$( ( cd "$TMP/rd3" && LOOM_LIVE="$TMP/rd3/live" LOOM_LOCK="instances/x/loom.lock.json" bash "$RH" --offline --dry-run 2>&1 ) )"
contains "RD3: the 4b header is printed under --dry-run" "4b. session deny list" "$O"
if [ -f "$TMP/rd3/live/settings.json" ]; then
  bad "RD3: --dry-run writes no settings.json" "it wrote one"
else ok "RD3: --dry-run writes no settings.json"; fi

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
