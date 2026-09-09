#!/usr/bin/env bash
# test-lock-verify-l15-session-deny.sh — L15: is every estate another record names, that
# THIS record does not, actually denied for a SESSION on this box?
#
# ⛔ WHY THIS EXISTS. L13 verifies THIS machine's own declared MCP source is present. It says
# nothing about every OTHER estate the kit's records name — mcp-profile-config.py --session-
# deny can DERIVE that list, wire-settings.py --deny-file can WRITE it, and rehydrate.sh step
# 4b can WIRE it on restore. Without this layer, a derivation that never got wired — a kit
# whose rehydrate predates 4b, a hand-edited settings.json, a stale run — sits unverified
# forever, exactly the "declared, installed, not wired" shape L8/L9 already fixed once.
#
# Usage: bash boot-kit/scripts/tests/test-lock-verify-l15-session-deny.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
LV="${LOCK_VERIFY:-$SCRIPTS/lock-verify.sh}"
[ -f "$LV" ] || { echo "missing $LV"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkinst() { mkdir -p "$1/vendor"; : > "$1/install.sh"; }

l15_block() { # -> just the [L15] section of lock-verify's output
  printf '%s\n' "$1" | awk '/^\[L15\]/{p=1} p{print} /^\[L15\]/{next} p && /^$/{exit}'
}

# A two-record kit, same SD1 shape used across the session-deny suites: the ROOT lockfile
# names two estates, instances/x names only one -- so from x's own record, the root names
# "claude.ai Estate B" that x does not, and that is what a session here must deny.
mktwo() { # $1 = dir
  mkinst "$1"
  mkdir -p "$1/instances/x"
  jq -n '{mcp:{profiles:{a:{kind:"hubs",servers:["hub-a"]}, b:{kind:"connector",servers:["claude.ai Estate B"]}}}}' \
    > "$1/loom.lock.json"
  jq -n '{mcp:{profiles:{a:{kind:"hubs",servers:["hub-a"]}}}}' \
    > "$1/instances/x/loom.lock.json"
}

echo "=== L15a: instance record, live settings deny the name -> PASS with N=1 ==="
A="$TMP/a"; mktwo "$A"
mkdir -p "$TMP/a-live"
jq -n '{deniedMcpServers:[{"serverName":"claude.ai Estate B"}]}' > "$TMP/a-live/settings.json"
outA="$(cd "$A" && LOOM_LIVE="$TMP/a-live" bash "$LV" --lock=instances/x/loom.lock.json 2>&1)"
la="$(l15_block "$outA")"
contains "L15a: PASS naming N=1" "PASS  L15 session deny: 1 server(s) other records name are denied for sessions here" "$la"
absent   "L15a: not reported as drift" "DRIFT L15" "$la"

echo "=== L15b: live settings lack it -> DRIFT naming it ==="
B="$TMP/b"; mktwo "$B"
mkdir -p "$TMP/b-live"
jq -n '{}' > "$TMP/b-live/settings.json"
outB="$(cd "$B" && LOOM_LIVE="$TMP/b-live" bash "$LV" --lock=instances/x/loom.lock.json 2>&1)"
lb="$(l15_block "$outB")"
contains "L15b: DRIFT naming the count" "DRIFT L15 session deny: 1 server(s) other records name are NOT denied for sessions here" "$lb"
contains "L15b: names the missing server" "claude.ai Estate B" "$lb"
contains "L15b: points at the fix" "rehydrate.sh step 4b" "$lb"

echo "=== L15c: the root record -> PASS 'nothing to deny' ==="
C="$TMP/c"; mktwo "$C"
mkdir -p "$TMP/c-live"
outC="$(cd "$C" && LOOM_LIVE="$TMP/c-live" bash "$LV" --lock=loom.lock.json 2>&1)"
lc="$(l15_block "$outC")"
contains "L15c: PASS nothing to deny" "PASS  L15 session deny: nothing to deny (no other record names an estate this one does not)" "$lc"
absent   "L15c: not reported as drift" "DRIFT L15" "$lc"

echo "=== L15d: the name present only in settings.local.json -> PASS (union) ==="
D="$TMP/d"; mktwo "$D"
mkdir -p "$TMP/d-live"
jq -n '{}' > "$TMP/d-live/settings.json"
jq -n '{deniedMcpServers:[{"serverName":"claude.ai Estate B"}]}' > "$TMP/d-live/settings.local.json"
outD="$(cd "$D" && LOOM_LIVE="$TMP/d-live" bash "$LV" --lock=instances/x/loom.lock.json 2>&1)"
ld="$(l15_block "$outD")"
contains "L15d: PASS via settings.local.json alone" "PASS  L15 session deny: 1 server(s) other records name are denied for sessions here" "$ld"
absent   "L15d: not reported as drift" "DRIFT L15" "$ld"

echo "=== L15e: python3 unreachable -> UNKNOWN, never a silent pass ==="
E="$TMP/e"; mktwo "$E"
mkdir -p "$TMP/e-live"
PATH_NO_PY="$TMP/no-python-path"
mkdir -p "$PATH_NO_PY"
for b in jq bash; do
  real="$(command -v "$b")"
  [ -n "$real" ] && ln -sf "$real" "$PATH_NO_PY/$b"
done
outE="$(cd "$E" && LOOM_LIVE="$TMP/e-live" PATH="$PATH_NO_PY" bash "$LV" --lock=instances/x/loom.lock.json 2>&1)"
le="$(l15_block "$outE")"
contains "L15e: UNKNOWN, python3 required" "UNKNOWN L15 session deny: python3 required" "$le"
absent   "L15e: never a silent pass" "PASS  L15" "$le"
absent   "L15e: never a false drift" "DRIFT L15" "$le"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
