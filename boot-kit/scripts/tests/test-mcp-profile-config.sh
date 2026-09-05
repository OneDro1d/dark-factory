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
    "optima":       {"url": "https://x/hub/c/mcp", "headers": {"Authorization": "Bearer LITERALTOKEN2"}},
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
absent   "M1 another estate's hub is NOT kept" '"optima"'       "$BODY"
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
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
