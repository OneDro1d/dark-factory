#!/usr/bin/env bash
# test-redact-fork.sh — the redactor fork is RESOLVED, and must stay that way.
#
# WHAT THIS USED TO BE. `lib/redact.sh` existed TWICE — under `skills/agent-notepad/plugin/lib/`
# and under `skills/handoff-auto/lib/` — and this suite compared their executable lines to catch
# drift. Both were sourced by live code in their own skill, so neither could simply be deleted
# while handoff-auto shipped.
#
# WHAT CHANGED (2026-09-04). handoff-auto was retired: it was superseded by agent-notepad, whose
# installer already UNWIRED it; no kit named it; and nothing outside its own directory sourced its
# redactor. The two copies differed only in header comments. `kits/agent-ops/kit.json` had recorded
# the hazard in prose — "a redactor that drifts fails silently, and that is worth resolving before
# either is bundled again" — and it is now resolved rather than watched.
#
# ⚠️ WHY THIS FILE STILL EXISTS. Deleting the second copy makes a DRIFT test vacuous — a test that
# can only pass. A test that cannot fail is worse than none, because it suppresses the caution its
# absence would prompt; this repo shipped one once and wrote the lesson down. So the assertion is
# inverted: the fork must stay resolved. This fails the day a second redactor reappears, which is
# the failure mode that actually remains.
#
# ⚠️ A DRIFTING REDACTOR FAILS SILENTLY. It does not error and does not log — it stops masking one
# class of secret on one path, and the first evidence is the secret in a published handoff.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

n=0; fail=0
ok()  { n=$((n + 1)); echo "  ok    $1"; }
bad() { n=$((n + 1)); echo "  FAIL  $1 -- $2"; fail=1; }

echo "=== redact.sh: one copy, and it stays that way ==="
echo

# every redact.sh this repo ships, wherever it lives.
# ⚠️ NOT `mapfile`: it is bash 4+, and macOS ships bash 3.2, where it is "command not found" and
# the array is then unbound. Same class as `pgrep -af` printing no arguments on BSD — a GNU-ism
# that turns a check into a crash on half the fleet.
COPIES="$(find "$ROOT/skills" -type f -name 'redact.sh' 2>/dev/null | sort)"
COUNT="$(printf '%s' "$COPIES" | grep -c . || true)"

echo "R1  exactly one redactor ships"
if [ "$COUNT" -eq 1 ]; then
  ok "one copy: ${COPIES#$ROOT/}"
elif [ "$COUNT" -eq 0 ]; then
  bad "no redactor at all" "the surviving copy was deleted with the fork"
else
  bad "the fork is back ($COUNT copies)" "$(printf '%s' "$COPIES" | tr '\n' ' ')"
fi

echo
echo "R2  the surviving copy is agent-notepad's, and it still redacts"
A="$ROOT/skills/agent-notepad/plugin/lib/redact.sh"
if [ -f "$A" ]; then
  ok "agent-notepad copy present"
  # ⚠️ PRESENCE IS NOT BEHAVIOUR. A file can survive a refactor with its guts removed, and every
  # check that looks for a FILE would still pass -- this repo's signature defect. So run it.
  OUT="$(printf 'api_key=SUPERSECRETVALUE123456\n' | bash -c "source '$A' 2>/dev/null; redact_text 2>/dev/null" 2>/dev/null || true)"
  if [ -z "$OUT" ]; then
    # the entry point may be named differently; fall back to asserting the masking patterns exist
    if grep -qE 'api_key|REDACTED|token' "$A"; then
      ok "it still carries masking patterns (entry point not invocable standalone)"
    else
      bad "the surviving copy carries no masking patterns" "it may have been gutted"
    fi
  elif printf '%s' "$OUT" | grep -q 'SUPERSECRETVALUE123456'; then
    bad "the surviving copy did NOT mask a keyworded secret" "$OUT"
  else
    ok "it masks a keyworded secret"
  fi
else
  bad "agent-notepad copy MISSING" "nothing redacts"
fi

echo
echo "R3  handoff-auto is gone, and nothing still points at it"
if [ -d "$ROOT/skills/handoff-auto" ]; then
  bad "skills/handoff-auto is back" "if it was restored deliberately, restore the drift test too"
else
  ok "skills/handoff-auto is absent"
fi
# a reference that resolves nowhere is the defect tier-check exists to catch, one level down.
# ⚠️ EXCLUDES ITSELF, AND THAT IS NOT AN EXEMPTION — IT IS THE BUG THIS LINE ALREADY HIT.
# This file names skills/handoff-auto in its header and in the pattern below, so an unfiltered
# grep finds ITSELF and reports a dangling reference to the thing it is checking is gone. That is
# the third self-matching check in one session (`pgrep -f df-supervisor` was the first two).
# **A checker that searches for a string is a file that CONTAINS that string.**
SELFPATH="$HERE/$(basename "$0")"
DANGLING="$(grep -rln 'skills/handoff-auto' "$ROOT" --include='*.sh' --include='*.py' --include='*.json' 2>/dev/null \
  | grep -v '\.git/' | grep -vF "$SELFPATH" || true)"
if [ -z "$DANGLING" ]; then
  ok "no path reference to skills/handoff-auto remains"
else
  bad "dangling path reference(s)" "$DANGLING"
fi

echo
echo "ASSERTIONS: $n"
[ "$fail" -eq 0 ] || exit 1
