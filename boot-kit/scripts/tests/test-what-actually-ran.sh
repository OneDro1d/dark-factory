#!/usr/bin/env bash
# test-what-actually-ran.sh — the two directives that fail leaving no trace stay documented.
#
# WHY THIS EXISTS. Two directives were measured failing SILENTLY AND IDENTICALLY, one week
# apart, and neither left a signature any reviewer could see.
#
#   SKILLS.     A binding named six skills to invoke. Naming is not loading -- skills
#               lazy-load, and nothing forces one. Live measurement 2026-09-01: six named,
#               TWO loaded, four skipped with no trace at all.
#   DELEGATION. The same session dispatched ZERO sub-agents and ZERO headless workers and did
#               every task inline at the top tier, including a pure enumeration the judgment
#               ladder puts at the cheapest tier. It never chose wrong; it never CHOSE --
#               df-dispatch-subagents was one of the four skills it did not load.
#
# Both produced correct work: green tests, green preflight, right files on disk. Every check
# that looked at the OUTPUT passed. That is the whole problem.
#
# ⚠️ THE FIX IS NOT COMPLIANCE, IT IS EVIDENCE OF COMPLIANCE. Auto-loading was measured and
# rejected: those six skills total ~936 lines, so loading them unconditionally spends 12-15k
# tokens on EVERY mission including ones needing none. Lazy loading is correct. So the record
# declares what ran, and an omission becomes a line a reviewer can see.
#
# ⚠️ WHAT THIS SUITE CAN AND CANNOT DO. It asserts the DOCTRINE IS PRESENT AND CONSISTENT
# across the two skills that carry it -- nothing more. It cannot check that a given session
# obeyed it; no test can, which is precisely why the mechanism is a written declaration read by
# a human gate. Saying that plainly here, so a green run is never read as "sessions comply".
#
# Usage: bash boot-kit/scripts/tests/test-what-actually-ran.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T1="$(cd "$SELF/../../.." && pwd)"
MAP="$T1/skills/vinculum-map/SKILL.md"
GATE="$T1/skills/df-adversary-gate/SKILL.md"
LADDER="$T1/skills/df-dispatch-subagents/SKILL.md"
for f in "$MAP" "$GATE" "$LADDER"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
has() { if grep -qF "$2" "$3"; then ok "$1"; else bad "$1" "'$2' not in $(basename "$3")"; fi; }

map="$(cat "$MAP")"; gate="$(cat "$GATE")"

echo "=== A: the map ships the declaration block ==="
has "A: map has the block"            "What actually ran"  "$MAP"
has "A: it records skills loaded"     "Skills loaded:"     "$MAP"
has "A: it records what was SKIPPED"  "Not loaded:"        "$MAP"
has "A: it records delegated vs inline" "Delegated:"       "$MAP"

echo "=== B: the map says WHY, so the rule survives being skimmed ==="
# A block with no incident behind it is one people talk themselves out of filling in.
case "$map" in *"Naming is not loading"*) ok "B: states naming != loading" ;;
  *) bad "B: states naming != loading" "the one-line reason is missing" ;; esac
case "$map" in *"never chose"*) ok "B: names the delegation failure as a non-choice" ;;
  *) bad "B: names the delegation failure" "missing" ;; esac
case "$map" in *"from what happened, not from the plan"*|*"from what happened"*)
  ok "B: warns against copying the plan into the record" ;;
  *) bad "B: warns against copying the plan" "a block copied from the binding records intent as outcome" ;; esac

echo "=== C: auto-loading is REJECTED with its measurement, not merely omitted ==="
# Without the number, the next reader re-proposes auto-loading and it sounds sensible.
case "$map" in *"936"*) ok "C: carries the measured cost of auto-loading" ;;
  *) bad "C: carries the measured cost" "no number, so the rejected option looks free" ;; esac
case "$map" in *"Do NOT solve this by auto-loading"*|*"not compliance, it is EVIDENCE"*)
  ok "C: rejects auto-loading explicitly" ;;
  *) bad "C: rejects auto-loading explicitly" "missing" ;; esac

echo "=== D: the gate can actually READ it — otherwise it is a line nobody checks ==="
has "D: gate references the block"       "What actually ran"        "$GATE"
has "D: gate points at the ladder"       "df-dispatch-subagents"    "$GATE"
case "$gate" in *"Absence of evidence is not evidence of compliance"*)
  ok "D: gate states the absence rule" ;;
  *) bad "D: gate states the absence rule" "missing" ;; esac
case "$gate" in *"No block at all"*)
  ok "D: a missing block is a finding, not a pass" ;;
  *) bad "D: a missing block is a finding" "the gate would silently accept an absent block" ;; esac

echo "=== E: neither file overclaims ==="
# The honesty constraint. A declaration proves a skill was LOADED, never that it changed the
# work -- exactly the doc-move gate's limit, and it must be stated in both places.
case "$map" in *"declaration, not a gate"*) ok "E: map says it is not a gate" ;;
  *) bad "E: map says it is not a gate" "missing" ;; esac
case "$gate" in *"a declaration is not proof"*|*"never that it changed how"*)
  ok "E: gate says a filled block is not proof" ;;
  *) bad "E: gate says a filled block is not proof" "missing" ;; esac

echo "=== F: the ladder the gate defers to still exists ==="
# The gate tells a reviewer to check right-sizing "against the judgment ladder". If that
# section is ever renamed, the instruction becomes a dangling reference -- the archived-link
# failure again, one skill over.
case "$(cat "$LADDER")" in *"Which tier"*) ok "F: df-dispatch-subagents still has the tier ladder" ;;
  *) bad "F: the tier ladder exists" "the gate defers to a section that no longer exists" ;; esac

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
