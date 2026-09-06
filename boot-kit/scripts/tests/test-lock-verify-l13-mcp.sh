#!/usr/bin/env bash
# test-lock-verify-l13-mcp.sh — L13: is the estate's declared MCP source actually present?
#
# WHY THIS EXISTS. `mcp.profiles.<estate>` names either a set of `~/.claude.json` hubs or a
# claude.ai CONNECTOR as the machine fact for how that estate's MCP is reached. Nothing
# checked that record against reality before this layer: a stale `hubs` list, or a connector
# that had quietly disconnected, would sit in the lockfile looking authoritative forever.
#
# ⚠️ THE THREE-WAY VERDICT IS THE POINT. `hubs` is checkable purely from JSON (no network), so
# it is always ok/drift, never unknown. `connector` needs a LIVE `claude mcp list`, so a
# machine with no `claude` on PATH can say NOTHING about whether it is connected — UNKNOWN,
# never a silent pass and never drift. `LOCK_VERIFY_CLAUDE_BIN` lets a test point at a stub
# `claude`, the same way `LOOM_LIVE` lets other suites here point at a stub hooks/skills root.
#
# Usage: bash boot-kit/scripts/tests/test-lock-verify-l13-mcp.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
LV="${LOCK_VERIFY:-$SCRIPTS/lock-verify.sh}"
[ -f "$LV" ] || { echo "missing $LV"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkinst() { # $1 = dir -> gives it install.sh (repo-root marker) + an empty vendor/
  mkdir -p "$1/vendor"
  : > "$1/install.sh"
}

l13_block() { # -> just the [L13] section of lock-verify's output
  printf '%s\n' "$1" | awk '/^\[L13\]/{p=1} p{print} /^\[L13\]/{next} p && /^$/{exit}'
}

echo "=== A: mcp.profiles undeclared -> one INFO line, never drift ==="
A="$TMP/a"; mkinst "$A"
jq -n '{vendorDir:"vendor", upstreams:{}}' > "$A/loom.lock.json"
outA="$(cd "$A" && LOOM_CLAUDE_JSON="$TMP/nope.json" bash "$LV" --lock=loom.lock.json 2>&1)"
la="$(l13_block "$outA")"
contains "A: names the undeclared state"      "mcp.profiles undeclared"            "$la"
contains "A: says the prefix rule is in force" "prefix rule in force"              "$la"
absent   "A: not reported as drift"           "DRIFT L13"                          "$la"

echo "=== B: kind hubs, every declared server present -> PASS ==="
B="$TMP/b"; mkinst "$B"
jq -n '{vendorDir:"vendor", upstreams:{}, mcp:{profiles:{onedroid:{kind:"hubs", servers:["onedroid","onedroid-dev"]}}}}' \
  > "$B/loom.lock.json"
CLAUDEJSON_B="$B/claude.json"
jq -n '{mcpServers:{onedroid:{url:"https://example-hub/a"}, "onedroid-dev":{url:"https://example-hub/b"}}}' \
  > "$CLAUDEJSON_B"
outB="$(cd "$B" && LOOM_CLAUDE_JSON="$CLAUDEJSON_B" bash "$LV" --lock=loom.lock.json 2>&1)"
lb="$(l13_block "$outB")"
contains "B: PASS for the hubs profile"        "PASS  L13 profile onedroid (hubs)"  "$lb"
absent   "B: no drift for this profile"        "DRIFT L13 profile onedroid"         "$lb"

echo "=== C: kind hubs, a declared server is missing -> DRIFT, named ==="
C="$TMP/c"; mkinst "$C"
jq -n '{vendorDir:"vendor", upstreams:{}, mcp:{profiles:{onedroid:{kind:"hubs", servers:["onedroid","ghost-hub"]}}}}' \
  > "$C/loom.lock.json"
CLAUDEJSON_C="$C/claude.json"
jq -n '{mcpServers:{onedroid:{url:"https://example-hub/a"}}}' > "$CLAUDEJSON_C"
outC="$(cd "$C" && LOOM_CLAUDE_JSON="$CLAUDEJSON_C" bash "$LV" --lock=loom.lock.json 2>&1)"
lc="$(l13_block "$outC")"
contains "C: DRIFT names the profile and kind" "DRIFT L13 profile onedroid (hubs)"  "$lc"
contains "C: the missing server is named"      "ghost-hub"                         "$lc"

echo "=== D: kind connector, claude mcp list shows Connected -> PASS ==="
D="$TMP/d"; mkinst "$D"
jq -n '{vendorDir:"vendor", upstreams:{}, mcp:{profiles:{eso:{kind:"connector", servers:["claude.ai Example"], toolPrefix:"mcp__claude_ai_Example__"}}}}' \
  > "$D/loom.lock.json"
STUB_CONNECTED="$TMP/claude-connected"
cat > "$STUB_CONNECTED" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
  printf 'claude.ai Example: https://example.invalid - \xe2\x9c\x94 Connected\n'
  exit 0
fi
exit 1
SH
chmod +x "$STUB_CONNECTED"
outD="$(cd "$D" && LOCK_VERIFY_CLAUDE_BIN="$STUB_CONNECTED" bash "$LV" --lock=loom.lock.json 2>&1)"
ld="$(l13_block "$outD")"
contains "D: PASS for the connected connector" "PASS  L13 profile eso (connector): claude.ai Example is Connected" "$ld"

echo "=== E: kind connector, claude mcp list shows no Connected line -> DRIFT ==="
E="$TMP/e"; mkinst "$E"
jq -n '{vendorDir:"vendor", upstreams:{}, mcp:{profiles:{eso:{kind:"connector", servers:["claude.ai Example"], toolPrefix:"mcp__claude_ai_Example__"}}}}' \
  > "$E/loom.lock.json"
STUB_ABSENT="$TMP/claude-absent"
cat > "$STUB_ABSENT" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
  printf 'onedroid: https://example-hub/a (HTTP) - \xe2\x9c\x94 Connected\n'
  exit 0
fi
exit 1
SH
chmod +x "$STUB_ABSENT"
outE="$(cd "$E" && LOCK_VERIFY_CLAUDE_BIN="$STUB_ABSENT" bash "$LV" --lock=loom.lock.json 2>&1)"
le="$(l13_block "$outE")"
contains "E: DRIFT — the connector never appears in the listing" "DRIFT L13 profile eso (connector)" "$le"
contains "E: names the missing connector"                        "claude.ai Example"                 "$le"

echo "=== F: kind connector, claude not on PATH -> UNKNOWN, never a silent pass ==="
F="$TMP/f"; mkinst "$F"
jq -n '{vendorDir:"vendor", upstreams:{}, mcp:{profiles:{eso:{kind:"connector", servers:["claude.ai Example"], toolPrefix:"mcp__claude_ai_Example__"}}}}' \
  > "$F/loom.lock.json"
outF="$(cd "$F" && LOCK_VERIFY_CLAUDE_BIN="$TMP/no-such-claude-binary-xyz" bash "$LV" --lock=loom.lock.json 2>&1)"
lf="$(l13_block "$outF")"
contains "F: UNKNOWN, probe could not run" "UNKNOWN L13 profile eso (connector)" "$lf"
absent   "F: never reported as drift"      "DRIFT L13 profile eso"              "$lf"
absent   "F: never reported as a pass"     "PASS  L13 profile eso"              "$lf"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
