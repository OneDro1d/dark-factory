#!/usr/bin/env bash
# test-mcp-profile-config.sh — the config that gives a headless iteration its hubs back.
#
# ⛔ THE BUG THIS GUARDS. df-supervisor passes `--setting-sources project`; MCP servers live at
# USER scope in ~/.claude.json; so every worker ran with NO MCP — no tracker, no memory, no
# observability — and could not report it, because a worker with no tracker cannot write to the
# tracker. The failure is SILENT BY CONSTRUCTION, which is exactly why it needs a test and not
# a validation run: the thing that would notice is the thing that is missing.
#
# Enrolled by GLOB, per tests/README.md — a suite is enrolled by existing.
#
# Usage: bash boot-kit/scripts/tests/test-mcp-profile-config.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
GATE="${MCP_PROFILE_CONFIG:-$SCRIPTS/mcp-profile-config.py}"
[ -f "$GATE" ] || { echo "missing $GATE"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcpcfg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CFG="$WORK/claude.json"
cat > "$CFG" <<'JSON'
{
  "mcpServers": {
    "onedroid":     {"url": "https://x/hub/a/mcp", "headers": {"Authorization": "Bearer LITERALTOKEN1"}},
    "onedroid-dev": {"url": "https://x/hub/b/mcp", "headers": {"Authorization": "Bearer ${DF_TEST_TOKEN_SET}"}},
    "hub-b":        {"url": "https://x/hub/c/mcp", "headers": {"Authorization": "Bearer LITERALTOKEN2"}},
    "onedroid-nx":  {"url": "https://x/hub/d/mcp", "headers": {"Authorization": "Bearer ${DF_TEST_TOKEN_UNSET}"}}
  }
}
JSON

# ---- 1. the profile's hubs, and ONLY the profile's hubs ----------------------
# Same rule as df-preflight.probe_mcp (a hub belongs to a profile when its NAME STARTS WITH the
# profile string), on purpose: a hub must not be in scope for the preflight and out of scope
# for the worker that preflight just cleared.
OUT="$(DF_TEST_TOKEN_SET=x DF_TEST_TOKEN_UNSET=y python3 "$GATE" \
        --profile onedroid --config "$CFG" --out "$WORK/out.json" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "M1 exits 0 on a matching profile"; else bad "M1 exits 0" "rc=$RC"; fi
BODY="$(cat "$WORK/out.json" 2>/dev/null)"
contains "M1 the profile hub is kept"          '"onedroid"'     "$BODY"
contains "M1 the profile's dev hub is kept"    '"onedroid-dev"' "$BODY"
absent   "M1 another estate's hub is NOT kept" '"hub-b"'        "$BODY"
if printf '%s' "$BODY" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
then ok "M1 the written config is valid JSON"; else bad "M1 valid JSON" "parse failed"; fi

# ---- 2. never print a token -------------------------------------------------
# ⚠️ This script's output is read into supervisor.log, which is committed.
absent "M2 a literal token never reaches stdout/stderr" "LITERALTOKEN1" "$OUT"

# ---- 3. the file is private -------------------------------------------------
MODE="$(python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" \
        "$WORK/out.json" 2>/dev/null)"
if [ "$MODE" = "0o600" ]; then ok "M3 the config is written 0600"
else bad "M3 the config is written 0600" "got $MODE"; fi

# ---- 4. REFUSE rather than write an empty config ----------------------------
# {"mcpServers":{}} with --strict-mcp-config is indistinguishable at runtime from the very bug
# this script exists to fix — and it would look like the fix had been applied.
python3 "$GATE" --profile nosuch --config "$CFG" --out "$WORK/none.json" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 4 ]; then ok "M4 exits 4 when no hub matches"; else bad "M4 exits 4" "rc=$RC"; fi
if [ -f "$WORK/none.json" ]; then bad "M4 nothing is written" "a file was written anyway"
else ok "M4 nothing is written"; fi

# ---- 5. the secret guard ----------------------------------------------------
# ⛔ These values are LITERAL bearer tokens on at least one machine in this estate (measured
# 2026-09-05). The natural home for a per-mission file is the mission dir; the mission dir is
# inside the notepad; the notepad is pushed every session. The obvious choice is the leaking
# one, so only a hard refusal catches it.
mkdir -p "$WORK/repo/sub"
git -c init.defaultBranch=main -C "$WORK/repo" init -q 2>/dev/null
python3 "$GATE" --profile onedroid --config "$CFG" --out "$WORK/repo/sub/out.json" \
        >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 5 ]; then ok "M5 exits 5 for a path inside a git work tree"
else bad "M5 exits 5 inside a repo" "rc=$RC"; fi
if [ -f "$WORK/repo/sub/out.json" ]; then bad "M5 no token-bearing file in a repo" "written"
else ok "M5 no token-bearing file in a repo"; fi

# ---- 6. an unset token var is REPORTED, never silent ------------------------
# A hub whose var is unset is CONFIGURED AND DEAD: children boot cleanly, fail every call, and
# keep looping. That is the documented stripped-environment failure this estate already paid
# for, so it warns — and it does NOT warn about a var that is set.
ERR="$(unset DF_TEST_TOKEN_UNSET; DF_TEST_TOKEN_SET=x python3 "$GATE" \
        --profile onedroid --config "$CFG" --out "$WORK/o2.json" 2>&1 >/dev/null)"
contains "M6 the unset var is named"      "DF_TEST_TOKEN_UNSET" "$ERR"
absent   "M6 a var that IS set is quiet"  "DF_TEST_TOKEN_SET,"  "$ERR"

# ---- 7. a missing/broken config is reported, not guessed at -----------------
python3 "$GATE" --profile onedroid --config "$WORK/nope.json" --out "$WORK/o3.json" \
        >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 2 ]; then ok "M7 exits 2 on an unreadable config"; else bad "M7 exits 2" "rc=$RC"; fi

echo ""
# ══ B24: mcp.profiles — a lockfile entry beats the name-prefix guess ═════════════════════
# The prefix rule above is a GUESS. When the instance lockfile DECLARES which servers serve
# an estate, that record is used instead — hubs (an exact server list) or a claude.ai
# connector (which appears in no file, so nothing is written; a PLAN line is printed instead).

# ---- 8. no entry for the profile: the OLD rule runs, plus one INFO line -----
LOCK_NOENTRY="$WORK/noentry.lock.json"
cat > "$LOCK_NOENTRY" <<'JSON'
{"mcp": {"profiles": {}}}
JSON
OUT8="$(python3 "$GATE" --profile onedroid --config "$CFG" --lock "$LOCK_NOENTRY" \
        --out "$WORK/o8.json" 2>&1)"; RC8=$?
if [ "$RC8" -eq 0 ]; then ok "L1 no mcp.profiles entry: exits 0 (prefix rule still runs)"
else bad "L1 no mcp.profiles entry: exits 0" "rc=$RC8: $OUT8"; fi
contains "L2 the INFO line names the undeclared profile" "mcp.profiles is undeclared for profile 'onedroid'" "$OUT8"
contains "L3 the INFO line is marked INFO"                "INFO"                                            "$OUT8"
BODY8="$(cat "$WORK/o8.json" 2>/dev/null)"
contains "L4 the prefix-rule hub is still kept" '"onedroid"' "$BODY8"

# ---- 9. kind hubs: EXACTLY the declared servers, not the prefix guess -------
LOCK_HUBS="$WORK/hubs.lock.json"
cat > "$LOCK_HUBS" <<'JSON'
{"mcp": {"profiles": {"onedroid": {"kind": "hubs", "servers": ["onedroid", "hub-b"]}}}}
JSON
OUT9="$(python3 "$GATE" --profile onedroid --config "$CFG" --lock "$LOCK_HUBS" \
        --out "$WORK/o9.json" 2>&1)"; RC9=$?
if [ "$RC9" -eq 0 ]; then ok "H1 hubs-from-lock exits 0"; else bad "H1 hubs-from-lock exits 0" "rc=$RC9: $OUT9"; fi
BODY9="$(cat "$WORK/o9.json" 2>/dev/null)"
contains "H2 the declared onedroid hub is kept" '"onedroid"' "$BODY9"
contains "H3 the declared hub-b IS kept (it is declared, prefix would exclude it)" '"hub-b"' "$BODY9"
absent   "H4 onedroid-dev is NOT kept (not in the declared list)" '"onedroid-dev"' "$BODY9"
absent   "H5 no INFO line when the profile IS declared" "mcp.profiles is undeclared" "$OUT9"

# ---- 10. kind hubs: a missing server exits 2, naming it, writes nothing ------
LOCK_MISSING="$WORK/missing.lock.json"
cat > "$LOCK_MISSING" <<'JSON'
{"mcp": {"profiles": {"onedroid": {"kind": "hubs", "servers": ["onedroid", "no-such-hub"]}}}}
JSON
OUT10="$(python3 "$GATE" --profile onedroid --config "$CFG" --lock "$LOCK_MISSING" \
         --out "$WORK/o10.json" 2>&1)"; RC10=$?
if [ "$RC10" -eq 2 ]; then ok "H6 a missing declared hub exits 2"; else bad "H6 a missing declared hub exits 2" "rc=$RC10"; fi
contains "H7 the refusal names the missing hub" "no-such-hub" "$OUT10"
if [ -f "$WORK/o10.json" ]; then bad "H8 nothing is written when a declared hub is missing" "a file was written anyway"
else ok "H8 nothing is written when a declared hub is missing"; fi

# ---- 11. kind connector: NO file written, a PLAN line on stdout -------------
LOCK_CONN="$WORK/connector.lock.json"
cat > "$LOCK_CONN" <<'JSON'
{"mcp": {"profiles": {"onedroid": {"kind": "connector", "servers": ["claude.ai Example"], "toolPrefix": "mcp__claude_ai_Example__"}}}}
JSON
OUT11="$(python3 "$GATE" --profile onedroid --config "$CFG" --lock "$LOCK_CONN" \
         --out "$WORK/o11.json" 2>&1)"; RC11=$?
if [ "$RC11" -eq 0 ]; then ok "C1 connector plan exits 0"; else bad "C1 connector plan exits 0" "rc=$RC11: $OUT11"; fi
if [ -f "$WORK/o11.json" ]; then bad "C2 no --mcp-config file is written for a connector" "a file was written"
else ok "C2 no --mcp-config file is written for a connector"; fi
PLAN_LINE="$(printf '%s\n' "$OUT11" | grep '^PLAN ')"
if [ -n "$PLAN_LINE" ]; then ok "C3 a PLAN line is printed"; else bad "C3 a PLAN line is printed" "none found in: $OUT11"; fi
PLAN_JSON="${PLAN_LINE#PLAN }"
if printf '%s' "$PLAN_JSON" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
then ok "C4 the PLAN payload is valid JSON"; else bad "C4 the PLAN payload is valid JSON" "parse failed: $PLAN_JSON"; fi
PLAN_MODE="$(printf '%s' "$PLAN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("mode"))')"
[ "$PLAN_MODE" = "connector" ] && ok "C5 plan mode is connector" || bad "C5 plan mode is connector" "got '$PLAN_MODE'"
PLAN_NAME="$(printf '%s' "$PLAN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name"))')"
[ "$PLAN_NAME" = "claude.ai Example" ] && ok "C6 plan names the connector server exactly" || bad "C6 plan names the connector server exactly" "got '$PLAN_NAME'"
PLAN_PREFIX="$(printf '%s' "$PLAN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("allowPrefix"))')"
[ "$PLAN_PREFIX" = "mcp__claude_ai_Example__" ] && ok "C7 allowPrefix is sanitised exactly ('claude.ai Example' -> 'claude_ai_Example')" \
                                                 || bad "C7 allowPrefix sanitised" "got '$PLAN_PREFIX'"
DISALLOW_HAS() { printf '%s' "$PLAN_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin).get('disallow', [])
sys.exit(0 if '$1' in d else 1)
"; }
if DISALLOW_HAS "mcp__onedroid__*"; then ok "C8 disallow denies the onedroid hub"; else bad "C8 disallow denies the onedroid hub" "absent"; fi
if DISALLOW_HAS "mcp__onedroid_dev__*"; then ok "C9 disallow denies onedroid-dev (sanitised)"; else bad "C9 disallow denies onedroid-dev (sanitised)" "absent"; fi
if DISALLOW_HAS "mcp__hub_b__*"; then ok "C10 disallow denies hub-b (sanitised)"; else bad "C10 disallow denies hub-b (sanitised)" "absent"; fi
if DISALLOW_HAS "mcp__plugin_*"; then ok "C11 disallow always includes mcp__plugin_*"; else bad "C11 disallow always includes mcp__plugin_*" "absent"; fi
absent "C12 a literal token never reaches stdout for a connector plan" "LITERALTOKEN1" "$OUT11"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
