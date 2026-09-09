#!/usr/bin/env bash
# test-validate-arm.sh — T1-F/T1-I: validate-arm.sh carries the machine record's own
# defaultProfile into M-VALIDATE, and its own LOOM_LOCK into the armed notepad's settings,
# so the ONE session inside a validate run that must launch a worker is not the one
# session where the record is unknown.
#
# ⛔ ALL THREE CASES BELOW ARE RED AGAINST THE PREVIOUS COMMIT'S TREE: validate-arm.sh did
# not write `.df/missions/M-VALIDATE/profile` at all, and never touched env.LOOM_LOCK in
# the copied settings.json. That is the point -- these are new deliverables, not a refactor
# of something that already passed.
#
# Kept SEPARATE from test-validate.sh (SPEC's own "or a new test-validate-arm.sh ... if
# cleaner") rather than folded in: these cases exercise mcp-profile-config.py's
# resolve_machine_lock() against fixture lockfiles, a different axis than that suite's
# stub-claude-binary session mechanics, and a fresh file means zero risk of colliding with
# its existing (already-green, must-stay-green) label names or fixtures. In particular,
# that suite's own `_fresh_kit` gives every fixture a single, machine-agnostic
# `loom.lock.json` -- exactly the shape this suite's A3b case asserts must NOT be carried
# as if it were a resolved machine record (see the gate on the `machine` block below).
#
# Enrolled by GLOB, per run-tests.sh -- a suite is enrolled by existing.
#
# Usage: bash boot-kit/scripts/tests/test-validate-arm.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
ARM="$SELF/../validate-arm.sh"
[ -f "$ARM" ] || { echo "missing $ARM"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in: $3" ;; esac; }
file_exists() { [ -e "$2" ] && ok "$1" || bad "$1" "missing: $2"; }
file_absent() { [ ! -e "$2" ] && ok "$1" || bad "$1" "unexpectedly present: $2"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/dfvalidatearm.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT

# _json_get FILE EXPR -> the python expression EXPR, evaluated against `d` (the parsed JSON
# doc, {} on any parse failure), OR'd with '' so a missing/None path prints an empty line
# rather than the literal string "None".
_json_get() {
  python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        d = json.load(fh) or {}
except Exception:
    d = {}
print($2 or '')
" "$1"
}

echo "=== A1: a root record with defaultProfile writes .df/missions/M-VALIDATE/profile ==="
KITA1="$T/kitA1"
mkdir -p "$KITA1"
printf '{"defaultProfile": "estate-b"}\n' > "$KITA1/loom.lock.json"
ARM_A1="$(bash "$ARM" "$KITA1" 2>&1)"; RC_A1=$?
[ "$RC_A1" -eq 0 ] && ok "A1: arm exits 0" || bad "A1: arm exits 0" "rc=$RC_A1: $ARM_A1"
PROF_A1="$KITA1/.df-validate/.df/missions/M-VALIDATE/profile"
file_exists "A1: .df/missions/M-VALIDATE/profile exists" "$PROF_A1"
contains "A1: it carries the record's defaultProfile" "estate-b" "$(cat "$PROF_A1" 2>/dev/null)"

echo "=== A5: arming writes .df/missions/M-VALIDATE/HARD-STOPS.md carrying the hard stops ==="
HS_A1="$KITA1/.df-validate/.df/missions/M-VALIDATE/HARD-STOPS.md"
file_exists "A5: HARD-STOPS.md exists" "$HS_A1"
contains "A5: it contains 'touch nothing outside'" "touch nothing outside" "$(cat "$HS_A1" 2>/dev/null)"
contains "A5: it names validate.sh" "validate.sh" "$(cat "$HS_A1" 2>/dev/null)"

echo "=== A1b: a record with NO defaultProfile -> no profile file ==="
KITA1B="$T/kitA1b"
mkdir -p "$KITA1B"
printf '{"kit": "kitA1b"}\n' > "$KITA1B/loom.lock.json"
bash "$ARM" "$KITA1B" >/dev/null 2>&1
file_absent "A1b: .df/missions/M-VALIDATE/profile is absent (no declared default)" \
  "$KITA1B/.df-validate/.df/missions/M-VALIDATE/profile"

echo "=== A2: kit .claude/settings.local.json's env.LOOM_LOCK carries into the arm ==="
KITA2="$T/kitA2"
mkdir -p "$KITA2/.claude"
LOOM_LOCK_A2="$KITA2/some/other/loom.lock.json"
printf '{"env": {"LOOM_LOCK": "%s"}}\n' "$LOOM_LOCK_A2" > "$KITA2/.claude/settings.local.json"
ARM_A2="$(bash "$ARM" "$KITA2" 2>&1)"; RC_A2=$?
[ "$RC_A2" -eq 0 ] && ok "A2: arm exits 0" || bad "A2: arm exits 0" "rc=$RC_A2: $ARM_A2"
NP_A2_SETTINGS="$KITA2/.df-validate/.claude/settings.json"
file_exists "A2: the notepad's .claude/settings.json exists (created for the carry -- the kit had no project settings.json to copy)" "$NP_A2_SETTINGS"
GOT_A2="$(_json_get "$NP_A2_SETTINGS" "d.get('env', {}).get('LOOM_LOCK')")"
[ "$GOT_A2" = "$LOOM_LOCK_A2" ] && ok "A2: env.LOOM_LOCK matches settings.local.json's value" \
  || bad "A2: env.LOOM_LOCK matches settings.local.json's value" "got '$GOT_A2' want '$LOOM_LOCK_A2'"
contains "A2: the arm states which record and how, on stdout" \
  "arm: LOOM_LOCK=$LOOM_LOCK_A2 (via settings.local.json)" "$ARM_A2"

echo "=== A3: no settings.local, but exactly one record resolves for this machine (platform+home fixture) ==="
KITA3="$T/kitA3"
mkdir -p "$KITA3"
cat > "$KITA3/loom.lock.json" <<'JSON'
{"machine": {"platform": "PLATFORM_PLACEHOLDER", "home": "HOME_PLACEHOLDER"}}
JSON
python3 - "$KITA3/loom.lock.json" <<'PY'
import json, os, platform, sys
p = sys.argv[1]; d = json.load(open(p))
d["machine"] = {"platform": platform.system(), "home": os.path.expanduser("~")}
json.dump(d, open(p, "w"), indent=1)
PY
ARM_A3="$(bash "$ARM" "$KITA3" 2>&1)"; RC_A3=$?
[ "$RC_A3" -eq 0 ] && ok "A3: arm exits 0" || bad "A3: arm exits 0" "rc=$RC_A3: $ARM_A3"
NP_A3_SETTINGS="$KITA3/.df-validate/.claude/settings.json"
file_exists "A3: the notepad's .claude/settings.json exists (created for the carry)" "$NP_A3_SETTINGS"
WANT_A3="$KITA3/loom.lock.json"
GOT_A3="$(_json_get "$NP_A3_SETTINGS" "d.get('env', {}).get('LOOM_LOCK')")"
[ "$GOT_A3" = "$WANT_A3" ] && ok "A3: env.LOOM_LOCK is the resolved record's absolute path" \
  || bad "A3: env.LOOM_LOCK is the resolved record's absolute path" "got '$GOT_A3' want '$WANT_A3'"
contains "A3: the arm states which record and how, on stdout" \
  "arm: LOOM_LOCK=$WANT_A3 (via resolved record)" "$ARM_A3"

echo "=== A3b: a lone but UNADDRESSED lockfile (no machine block) is never guessed as this machine's record ==="
KITA3B="$T/kitA3b"
mkdir -p "$KITA3B"
printf '{"kit": "kitA3b"}\n' > "$KITA3B/loom.lock.json"
bash "$ARM" "$KITA3B" >/dev/null 2>&1
file_absent "A3b: no .claude/ was invented for an unaddressed lockfile" "$KITA3B/.df-validate/.claude"

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
