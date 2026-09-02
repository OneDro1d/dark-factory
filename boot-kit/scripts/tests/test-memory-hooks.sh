#!/usr/bin/env bash
# test-memory-hooks.sh — the promoted memory hooks must be safe to wire on ANY machine.
#
# WHY THIS EXISTS. These two were `local:` content in two separate instance repos until
# 2026-09-02, installed by hand on four machines and declared by no lockfile on three of
# them. Nothing tested them, because a hook that lives in one instance is nobody's to test.
# Promoting them makes them everyone's — so they get a contract.
#
# ⚠️ THE FAILURE MODE A HOOK HAS THAT A SKILL DOES NOT: it runs on every session, inside the
# harness's critical path, and a malformed line of stdout is not a bad answer — it is a
# broken session. Non-zero exit, invalid JSON and stray stdout are all worse than the hook
# simply not existing.
#
# ⚠️ AND THE ONE THAT PUT THEM HERE: these live in a PUBLIC repo now. An endpoint, a token or
# a hub name added later would be published. Case D fails the suite if one appears.
#
# Engram is the memory store these hooks name. What it is and how to reach it is documented
# in exactly one place: [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
#
# ⚠️ That pointer is not decoration — test-engram-references.sh R2 requires every tracked file
# naming Engram to carry it, and R3 requires it to resolve at the right relative depth. This
# suite failed that rule on its first run, which is the rule working.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
T1="$(cd "$SELF/../../.." && pwd)"
HOOKS="$T1/hooks"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

SUBJECTS="engram-stop.sh engram-pre-compact.sh"

echo "=== A: present and executable ==="
for h in $SUBJECTS; do
  if [ -f "$HOOKS/$h" ]; then ok "A: $h exists"
  else bad "A: $h exists" "not promoted"; continue; fi
done

echo "=== B: exits 0 on a well-formed event, and on a malformed one ==="
# A hook that fails closed takes the session with it. Both cases must exit 0.
for h in $SUBJECTS; do
  [ -f "$HOOKS/$h" ] || continue
  if printf '{"session_id":"t","cwd":"/tmp","transcript_path":""}' \
       | bash "$HOOKS/$h" >/dev/null 2>&1; then ok "B: $h exits 0 on valid stdin"
  else bad "B: $h exits 0 on valid stdin" "non-zero exit blocks the session"; fi
  if printf 'not json at all' | bash "$HOOKS/$h" >/dev/null 2>&1; then
    ok "B: $h exits 0 on malformed stdin"
  else bad "B: $h exits 0 on malformed stdin" "non-zero exit"; fi
done

echo "=== C: stdout is either empty or a single valid JSON object ==="
# The harness parses stdout. Anything else is a broken session, not a bad answer.
for h in $SUBJECTS; do
  [ -f "$HOOKS/$h" ] || continue
  out="$(printf '{"session_id":"t","cwd":"/tmp","transcript_path":""}' \
          | bash "$HOOKS/$h" 2>/dev/null)"
  if [ -z "$out" ]; then ok "C: $h emits nothing (valid)"; continue; fi
  if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "C: $h emits valid JSON"
  else bad "C: $h emits valid JSON" "unparseable stdout would break the session"; fi
done

echo "=== D: no endpoint, token or hub name — this repo is PUBLIC ==="
for h in $SUBJECTS; do
  [ -f "$HOOKS/$h" ] || continue
  # Match a real URL or a bearer/token assignment. The WORD "token" is fine in prose.
  if grep -qE 'https?://|[Bb]earer [A-Za-z0-9]|(TOKEN|SECRET|API_KEY)=[^ ]' "$HOOKS/$h"; then
    bad "D: $h carries no endpoint or credential" "found one -- this repo is public"
  else
    ok "D: $h carries no endpoint or credential"
  fi
  # Hub names are an ESTATE binding and must not be committed upstream.
  if grep -qE 'onedroid\.ai|esosuite|mcp__(onedroid|optima|claude_ai_ESO)' "$HOOKS/$h"; then
    bad "D: $h names no estate hub" "a hub name here is a binding in the generic tier"
  else
    ok "D: $h names no estate hub"
  fi
done

echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
