#!/usr/bin/env bash
# test-gate-headless-release.sh — the completeness gate must not overwrite a worker's answer.
#
# Enrolled by GLOB, per tests/README.md — "a suite is enrolled by existing".
#
# ⛔ WHAT IT PROTECTS. A Stop hook that emits ANYTHING means "not finished", so the model takes
# another turn and THAT turn's text becomes the run's `result`. Interactively that is the point —
# a human reads the prompt. In `claude -p` nobody reads it, and the only effect is that the
# worker's ANSWER is replaced by prose about completeness. Promise-Theory dispatch reads exactly
# that field as evidence, so contaminating it defeats the contract this repo is built on.
#
# Measured 2026-09-04 by the ESO kit-validation run:
#   claude -p 'Reply with exactly this and nothing else: MARKER-9F3A-OK'
#     -> result = "Nothing outstanding. The turn was a single instruction…"
#
# ⚠️ THE DISCRIMINATOR WAS FILED AS A GUESS AND THE GUESS WAS WRONG. The patch proposed
# CLAUDE_CODE_ENTRYPOINT == "cli-print" and said plainly it must be verified. Dumping the
# environment inside a real headless run:
#     interactive   cli
#     headless -p   sdk-cli
# "cli-print" occurs nowhere — pasted as filed the fix would have been INERT. This suite pins the
# measured value so a future edit cannot quietly reintroduce a value that never fires.
#
# ⚠️ AND IT PINS THE FAIL-SAFE DIRECTION. An unknown entrypoint must keep GATING. If the harness
# renames the value, the gate becomes too talkative in workers again — the defect being fixed —
# rather than silently switching off in interactive sessions, where a human relies on it.
#
# Usage: bash boot-kit/scripts/tests/test-gate-headless-release.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF/../../.." && pwd)"
GATE="$ROOT/hooks/mission-completeness-gate.py"
[ -f "$GATE" ] || { echo "missing $GATE"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

EVENT='{"stop_hook_active": false, "cwd": "'"$ROOT"'"}'

echo "=== A: a HEADLESS run releases — the worker keeps its own answer ==="
OUT="$(printf '%s' "$EVENT" | CLAUDE_CODE_ENTRYPOINT=sdk-cli python3 "$GATE" 2>&1)"; RC=$?
if [ -z "$OUT" ]; then ok "A emits nothing under sdk-cli"; else bad "A emits nothing under sdk-cli" "emitted: $(printf '%s' "$OUT" | head -c 120)"; fi
if [ "$RC" -eq 0 ]; then ok "A exits 0"; else bad "A exits 0" "got $RC"; fi

echo "=== B: an INTERACTIVE run still gates — this is the whole value of the hook ==="
# ⚠️ The fix must not disable the gate where a human reads it. That would trade a contaminated
# worker field for a silently missing completeness check, which is the worse of the two.
OUT="$(printf '%s' "$EVENT" | CLAUDE_CODE_ENTRYPOINT=cli python3 "$GATE" 2>&1)"; RC=$?
if [ -n "$OUT" ]; then ok "B still emits under cli"; else bad "B still emits under cli" "silent — the gate was disabled interactively"; fi

echo "=== C: an UNKNOWN entrypoint FAILS SAFE (keeps gating) ==="
# A positive test for headless, never a negative test for interactive. If the harness renames the
# value, we want the old noisy behaviour back, not a gate that quietly stops.
OUT="$(printf '%s' "$EVENT" | CLAUDE_CODE_ENTRYPOINT=some-future-name python3 "$GATE" 2>&1)"
if [ -n "$OUT" ]; then ok "C an unrecognised entrypoint keeps gating"; else bad "C unrecognised entrypoint keeps gating" "released — fails OPEN on a rename"; fi
OUT="$(printf '%s' "$EVENT" | env -u CLAUDE_CODE_ENTRYPOINT python3 "$GATE" 2>&1)"
if [ -n "$OUT" ]; then ok "C an ABSENT entrypoint keeps gating"; else bad "C absent entrypoint keeps gating" "released — fails OPEN when unset"; fi

echo "=== D: stop_hook_active still releases, unchanged ==="
# The pre-existing loop guard (T1 #82) must survive this change.
OUT="$(printf '{"stop_hook_active": true, "cwd": "%s"}' "$ROOT" | CLAUDE_CODE_ENTRYPOINT=cli python3 "$GATE" 2>&1)"
if [ -z "$OUT" ]; then ok "D stop_hook_active=true still releases"; else bad "D stop_hook_active=true still releases" "emitted"; fi

echo "=== E: the discriminator is the MEASURED value, not the filed guess ==="
if grep -q '"sdk-cli"' "$GATE"; then ok "E gate tests for sdk-cli (measured)"; else bad "E gate tests for sdk-cli" "the measured value is gone"; fi
# ⚠️ EXECUTABLE LINES ONLY, and that is not a loophole — it is the bug this pair already hit.
# The first version grepped the whole file and matched the gate's own COMMENTS explaining why
# "cli-print" occurs nowhere and why isatty discriminates nothing. Those comments are the most
# useful lines in the patch: they are what stops the next author reinstating either. A check that
# forbids DOCUMENTING a mistake pushes the reasoning out of the file.
# (Fourth self-matching check in one session: a checker that searches for a string flags every
#  file that discusses that string.)
CODE="$(grep -v '^[[:space:]]*#' "$GATE")"
if printf '%s' "$CODE" | grep -q 'cli-print'; then
  bad "E no cli-print in code" "that value occurs in no run — the check would be inert"
else
  ok "E does not test for cli-print in code (it never occurs)"
fi
if printf '%s' "$CODE" | grep -q 'isatty'; then
  bad "E no isatty discriminator in code" "isatty is false in both cases; it discriminates nothing"
else
  ok "E does not lean on isatty in code (false in both cases)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
# ⚠️ REQUIRED BY run-tests.sh: a suite that exits 0 declaring no count is UNMEASURED, not PASS.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
