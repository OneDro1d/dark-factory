#!/usr/bin/env bash
# test-render-hooks.sh — the renderer must refuse what cannot work, AND emit the right shape.
#
# ⚠️ WHY THIS SUITE EXISTS SEPARATELY FROM `--self-test`, which is the interesting part.
# The renderer's own self-test writes every render to /dev/null and checks only the EXIT
# CODE. That makes it a complete test of the refusal logic and NO test at all of the output:
# a renderer that exited 0 while emitting `{}`, or emitting Claude Code's shape under Codex's
# filename, would pass it every time. Exit-code-only testing is the same false-assurance
# family as a suite that declares no assertion count — the run is green and the denominator
# is unknown.
#
# So this suite asserts on the CONTENT, and on the two facts that make the content correct:
#
#   the KEY CASE      `SessionStart` for Claude Code, `session_start` for Codex
#   the NESTING       Claude Code wraps commands in a matcher group (`[{hooks:[…]}]`);
#                     Codex does not. Same hook, two structures, and getting this wrong
#                     produces a file each harness parses and silently ignores.
#
# Both are measured facts from `reference/codex-hook-contract.md`, not conventions.
#
# Usage: bash boot-kit/scripts/tests/test-render-hooks.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
R="${RENDER_HOOKS:-$SCRIPTS/render-hooks.py}"
[ -f "$R" ] || { echo "missing $R"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] wanted [$3]"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rh.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

INJECT_START='{"hooks":[{"name":"ctx.sh","event":"SessionStart","command":"bash ctx.sh","timeout":10,"injects":true}]}'
printf '%s' "$INJECT_START" > "$WORK/start.json"

echo "=== A: the refusal logic (the renderer's own canaries) ==="
OUT="$(python3 "$R" --self-test 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok "A1 self-test exits 0" || bad "A1 self-test exits 0" "rc=$RC"
case "$OUT" in *"SELFTEST PASS"*) ok "A2 self-test reports PASS" ;; *) bad "A2 self-test reports PASS" "no PASS line" ;; esac
# Named individually: a self-test that stopped running a case would still print PASS, and the
# case most likely to be dropped is the one that was hardest to get right.
for c in "injecting hook on Codex PreCompact is REFUSED" \
         "a side-effect-only hook on PreCompact renders" \
         "SessionEnd is refused for codex" \
         "Stop is refused for codex" \
         "a missing \`injects\` is fatal" \
         "one bad hook refuses the WHOLE render"; do
  case "$OUT" in *"$c"*) ok "A3 case ran: $c" ;; *) bad "A3 case ran: $c" "absent" ;; esac
done

echo "=== B: the Claude Code shape — matcher group, PascalCase key ==="
python3 "$R" --manifest "$WORK/start.json" --harness claude-code > "$WORK/cc.json" 2>"$WORK/cc.err"
RC=$?
[ "$RC" -eq 0 ] && ok "B1 renders" || bad "B1 renders" "rc=$RC $(cat "$WORK/cc.err")"
eq "B2 key is PascalCase SessionStart" \
   "$(jq -r '.hooks | keys[]' "$WORK/cc.json" 2>/dev/null)" "SessionStart"
# The matcher-group nesting: .hooks.SessionStart[0].hooks[0]. One level too few and Claude
# Code reads no commands at all, from a file that is still valid JSON.
eq "B3 command sits inside a matcher group" \
   "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$WORK/cc.json" 2>/dev/null)" "bash ctx.sh"
eq "B4 the entry carries type=command" \
   "$(jq -r '.hooks.SessionStart[0].hooks[0].type' "$WORK/cc.json" 2>/dev/null)" "command"
eq "B5 timeout is carried through" \
   "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$WORK/cc.json" 2>/dev/null)" "10"

echo "=== C: the Codex shape — snake_case key, NO matcher group ==="
python3 "$R" --manifest "$WORK/start.json" --harness codex > "$WORK/cx.json" 2>"$WORK/cx.err"
RC=$?
[ "$RC" -eq 0 ] && ok "C1 renders" || bad "C1 renders" "rc=$RC $(cat "$WORK/cx.err")"
eq "C2 key is snake_case session_start" \
   "$(jq -r '.hooks | keys[]' "$WORK/cx.json" 2>/dev/null)" "session_start"
# Flat: .hooks.session_start[0].command. If the renderer ever emitted Claude Code's extra
# nesting here, this returns null while the file still parses.
eq "C3 command sits DIRECTLY in the array, no matcher group" \
   "$(jq -r '.hooks.session_start[0].command' "$WORK/cx.json" 2>/dev/null)" "bash ctx.sh"
eq "C4 no Claude Code nesting leaked in" \
   "$(jq -r '.hooks.session_start[0].hooks // "absent"' "$WORK/cx.json" 2>/dev/null)" "absent"
eq "C5 no type field — Codex does not use one" \
   "$(jq -r '.hooks.session_start[0].type // "absent"' "$WORK/cx.json" 2>/dev/null)" "absent"

echo "=== D: nothing is written when any hook is unrenderable ==="
# A partial render is the dangerous outcome: the hooks that DID render make the file look
# right, so the missing one is invisible until the behaviour is missed.
printf '%s' '{"hooks":[{"name":"a.sh","event":"SessionStart","command":"bash a.sh","injects":true},{"name":"b.sh","event":"PreCompact","command":"bash b.sh","injects":true}]}' > "$WORK/mixed.json"
rm -f "$WORK/partial.json"
python3 "$R" --manifest "$WORK/mixed.json" --harness codex --out "$WORK/partial.json" >/dev/null 2>"$WORK/mixed.err"
RC=$?
[ "$RC" -eq 1 ] && ok "D1 a mixed manifest exits 1" || bad "D1 a mixed manifest exits 1" "rc=$RC"
[ ! -f "$WORK/partial.json" ] && ok "D2 NO output file was written" \
  || bad "D2 NO output file was written" "a partial render landed on disk"
grep -q 'DISCARDS' "$WORK/mixed.err" && ok "D3 the reason names the discard" \
  || bad "D3 the reason names the discard" "no explanation given"
# ...and the good hook is NOT silently dropped from the report either.
grep -q 'b.sh' "$WORK/mixed.err" && ok "D4 the offending hook is named" \
  || bad "D4 the offending hook is named" "not named"

echo "=== E: the rendered Claude Code shape matches the shipped template ==="
# The instance kit ships settings.template.json with a hand-written SessionStart entry. If
# the renderer's shape and the template's shape ever diverge, one of them is wrong and the
# machine gets whichever ran last.
TPL="$SCRIPTS/../../starter-kit/instance/boot-kit/settings.template.json"
if [ -f "$TPL" ]; then
  eq "E1 template uses the same matcher-group nesting" \
     "$(jq -r '.hooks.SessionStart[0].hooks[0].type' "$TPL" 2>/dev/null)" "command"
  eq "E2 template key is PascalCase too" \
     "$(jq -r '.hooks | keys[]' "$TPL" 2>/dev/null)" "SessionStart"
else
  bad "E1 settings.template.json is present" "not found at $TPL"
fi

echo ""
printf 'render-hooks: %d ok, %d failed\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
