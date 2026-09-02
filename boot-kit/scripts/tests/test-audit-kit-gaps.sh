#!/usr/bin/env bash
# test-audit-kit-gaps.sh — the fleet gap detector must refuse to pass vacuously.
#
# ⚠️ THIS SUITE EXISTS BECAUSE THE DETECTOR SHIPPED WITH TWO OF THE BUGS IT HUNTS, and both
# were caught by DISBELIEVING A ZERO rather than by reading the code:
#
#   1. it looked for the settings template at ONE path, so a kit without one was SKIPPED
#      silently and counted clean. Five kits reported no findings; three had never been read.
#   2. it matched hook names by BASENAME, so `agent-notepad/hooks/pre-compact.sh` counted as
#      wired because the template contained `engram-pre-compact.sh` — same ending.
#
# Both are the same shape as the defects it is built to find: a check that answers "fine"
# without having looked. So the cases below are mostly about the DETECTOR'S OWN honesty, not
# about the fleet.
#
# Engram is the memory store the audited kits name. What it is and how to reach it is
# documented in exactly one place:
# [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
T1="$(cd "$SELF/../../.." && pwd)"
AUDIT="$T1/boot-kit/scripts/audit-kit-gaps.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== A: present, and refuses to guess ==="
if [ -f "$AUDIT" ]; then ok "A: audit exists"; else bad "A: audit exists" "not promoted"; fi

# ⚠️ NO ARGUMENTS MUST NOT MEAN "SCAN A DEFAULT LIST". A default would be one machine's
# layout, and an audit that scans nothing while exiting 0 is worse than no audit.
if python3 "$AUDIT" >/dev/null 2>&1; then
  bad "A: refuses to run with no kit roots" "exited 0 having scanned nothing"
else
  ok "A: refuses to run with no kit roots"
fi

# ⚠️ CAPTURE FIRST, THEN MATCH. `python3 "$AUDIT" | grep -q` under `set -o pipefail` takes
# python's deliberate exit 2 as the PIPELINE's status, so a correct refusal reads as a failed
# assertion. The script was right and the test was wrong — the same caller-vs-callee shape as
# the VR7 link-check bug, reproduced inside the suite written to catch such things.
USAGE_OUT="$(python3 "$AUDIT" 2>&1 || true)"
case "$USAGE_OUT" in *usage:*) ok "A: prints usage" ;;
  *) bad "A: prints usage" "a refusal with no instruction is just a failure" ;; esac

echo "=== B: a kit declaring hooks with NO settings template is a FINDING, not a skip ==="
K="$TMP/no-template"
mkdir -p "$K"
cat > "$K/loom.lock.json" <<'JSON'
{ "instance": "t-no-template", "vendorDir": "vendor",
  "install": { "hooks": ["a.sh"], "hookSources": { "a.sh": "local:hooks/a.sh" } } }
JSON
OUT="$(python3 "$AUDIT" "$K" 2>&1)"
case "$OUT" in *"NO settings template"*) ok "B: absence of a template is reported" ;;
  *) bad "B: absence of a template is reported" "silently skipped — the original bug" ;; esac

echo "=== C: hook matching is by FULL declared name, not by basename ==="
K2="$TMP/substring"
mkdir -p "$K2/boot-kit/config"
cat > "$K2/loom.lock.json" <<'JSON'
{ "instance": "t-substring", "vendorDir": "vendor",
  "install": { "hooks": ["np/hooks/pre-compact.sh"],
               "hookSources": { "np/hooks/pre-compact.sh": "local:x" } } }
JSON
# the template wires a DIFFERENT hook whose name ENDS with the same characters
cat > "$K2/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": { "PreCompact": [ { "matcher": "", "hooks": [
  { "type": "command", "command": "__HOME__/.claude/hooks/engram-pre-compact.sh" } ] } ] } }
JSON
OUT2="$(python3 "$AUDIT" "$K2" 2>&1)"
case "$OUT2" in *"np/hooks/pre-compact.sh"*) ok "C: substring near-miss is still reported" ;;
  *) bad "C: substring near-miss is still reported" \
        "engram-pre-compact.sh swallowed pre-compact.sh — the original bug" ;; esac

echo "=== D: a recorded decision is not a finding ==="
# ⚠️ The third state. A hook wired on ONE machine and deliberately absent from a template
# several instances share is neither "in the template" nor "inert". Reporting it forever is a
# false alarm, and the audit committed exactly that against its own fleet.
K3="$TMP/per-instance"
mkdir -p "$K3/boot-kit/config"
cat > "$K3/loom.lock.json" <<'JSON'
{ "instance": "t-per-instance", "vendorDir": "vendor",
  "install": { "hooks": ["solo.sh"], "hookSources": { "solo.sh": "local:x" },
               "$perInstanceWiring": "solo.sh is wired on this machine only, on purpose." } }
JSON
cat > "$K3/boot-kit/config/settings.json.template" <<'JSON'
{ "hooks": {} }
JSON
OUT3="$(python3 "$AUDIT" "$K3" 2>&1)"
case "$OUT3" in *"solo.sh: declared"*)
    bad "D: \$perInstanceWiring silences the finding" "reported an already-recorded decision" ;;
  *) ok "D: \$perInstanceWiring silences the finding" ;; esac

echo "=== E: prose ABOUT a dangling reference is not a dangling reference ==="
# Same rule test-binding-invokes-generics learned: match the instruction, not the warning.
K4="$TMP/prose"
mkdir -p "$K4"
cat > "$K4/loom.lock.json" <<'JSON'
{ "instance": "t-prose", "vendorDir": "vendor", "install": { "skills": [] } }
JSON
printf 'It used to open Skill(gone-skill) and that was a dangling reference.\n' \
  > "$K4/START-HERE.md"
OUT4="$(python3 "$AUDIT" "$K4" 2>&1)"
case "$OUT4" in *"cites Skill(gone-skill)"*)
    bad "E: prose about a dangling ref is exempt" "flagged the warning as the defect" ;;
  *) ok "E: prose about a dangling ref is exempt" ;; esac

# ...but a real instruction still is one
printf 'Load Skill(gone-skill) before you start.\n' > "$K4/START-HERE.md"
OUT5="$(python3 "$AUDIT" "$K4" 2>&1)"
case "$OUT5" in *"cites Skill(gone-skill)"*) ok "E: a real instruction is still reported" ;;
  *) bad "E: a real instruction is still reported" "the exemption swallowed the rule" ;; esac

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
