#!/usr/bin/env bash
# test-tier1-generic.sh — the genericity gate must be able to fail, and must be green HERE.
#
# WHY BOTH HALVES. `--self-test` proves the gate catches planted canaries in a scratch tree.
# That is necessary and it is not sufficient: a gate can be perfectly capable of failing and
# still be pointed at nothing, or be silenced wholesale by an allow-list that grew unread.
# So this suite also asserts things about THIS repo — that the gate runs clean on it today,
# that the vocabulary is real, and that every standing exception carries a reason.
#
# The second half is what makes the gate a ratchet. Tier 1 is green as of 2026-08-30 with six
# recorded exceptions; the next artifact that names a stack turns this suite red in CI.
#
# ⚠️ THE ALLOW-LIST ASSERTIONS ARE THE POINT, not paperwork. The realistic way this gate dies
# is not deletion — it is somebody appending a path to tier1-generic-allow.conf to get a
# merge through. That still costs them a written reason in a committed file, and a stale
# entry fails the build, so the list cannot quietly become the whole repo.
#
# Usage: bash boot-kit/scripts/tests/test-tier1-generic.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
ROOT="$(cd "$SCRIPTS/../.." && pwd)"
GATE="$SCRIPTS/tier1-generic.py"
VOCAB="$SCRIPTS/tier1-generic.conf"
ALLOW="$SCRIPTS/tier1-generic-allow.conf"
[ -f "$GATE" ] || { echo "missing $GATE"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }

echo "=== A: the gate can fail (its own canaries) ==="
OUT="$(python3 "$GATE" --self-test 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok "A1 self-test exits 0" || bad "A1 self-test exits 0" "rc=$RC"
contains "A2 self-test says it caught its canaries" "SELFTEST PASS" "$OUT"
# Named individually: a self-test that silently stopped running a case would still print
# PASS, and the case most likely to be dropped is the one that was hardest to get right.
contains "A3 the product-vs-category control ran"  "ONE category, is naming alternatives" "$OUT"
contains "A4 the matched canary for it ran"        "TWO categories is a stack"            "$OUT"
contains "A5 the self-exemption canary ran"        "body mentions cannot self-exempt"     "$OUT"
contains "A6 the tool-skill control ran"           "names its declared subject"           "$OUT"
contains "A7 the unreasoned-exception canary ran"  "exception with no reason fails"       "$OUT"
contains "A8 the stale-exception canary ran"       "stale exception fails"                "$OUT"
contains "A9 the empty-vocabulary canary ran"      "empty vocabulary must be FATAL"       "$OUT"
# The menu-vs-stack cases, added 2026-08-31 with the prose-block rule. Named individually
# for the same reason as A3–A9, and because these four are a matched SET: three controls
# that must pass and the canary that stops "tables and code are exempt" becoming "anything
# is exempt". A set is the easy thing to half-drop.
contains "A10 the bullet-list stack canary ran"    "spread down consecutive bullets"      "$OUT"
contains "A11 the table-catalogue control ran"     "one concern per table row"            "$OUT"
contains "A12 the code-fence control ran"          "fenced code block is a catalogue"     "$OUT"
contains "A13 the matched prose canary ran"        "composed in prose DO couple"          "$OUT"
# The structural one. If blocks stopped splitting on blank lines every file would collapse
# into a single block and the rule would silently revert to the file-wide count it replaced
# — passing this suite the whole way, because every other case is one block anyway.
contains "A14 the block-splitting control ran"     "blank line really does separate"      "$OUT"

echo "=== B: the gate is green on THIS repo, and that is a ratchet ==="
OUT="$(python3 "$GATE" "$ROOT" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then
  ok "B1 Tier 1 passes the genericity gate"
else
  bad "B1 Tier 1 passes the genericity gate" "rc=$RC — a new artifact names a stack, or an exception went stale; run: python3 boot-kit/scripts/tier1-generic.py"
fi
contains "B2 the verdict line is present" "=== RESULT:" "$OUT"

echo "=== C: the vocabulary is real, categorised, and ships ==="
[ -f "$VOCAB" ] && ok "C1 the vocabulary is committed, unlike landmarks.conf" \
  || bad "C1 the vocabulary is committed" "no $VOCAB"
# Committed is the whole reason this gate works in CI where the publish gate does not
# (ticket 12915091248). If it ever gets gitignored, this gate silently becomes decorative.
if git -C "$ROOT" check-ignore -q "$VOCAB" 2>/dev/null; then
  bad "C2 the vocabulary is NOT gitignored" "it is ignored — CI would run without it"
else
  ok "C2 the vocabulary is NOT gitignored"
fi
NCAT="$(grep -c '^\[' "$VOCAB" 2>/dev/null || echo 0)"
NPROD="$(grep -cE '^[a-z0-9.-]+$' "$VOCAB" 2>/dev/null || echo 0)"
[ "$NCAT" -ge 3 ] && ok "C3 at least 3 categories ($NCAT)" || bad "C3 at least 3 categories" "got $NCAT"
[ "$NPROD" -ge 10 ] && ok "C4 at least 10 products ($NPROD)" || bad "C4 at least 10 products" "got $NPROD"
# `amqp` is a PROTOCOL. It was in the first draft, inflated every RabbitMQ artifact with a
# second token for one decision, and was removed by the file's own stated test. Pinned so it
# cannot drift back in with the next person who greps for queue nouns.
if grep -qx 'amqp' "$VOCAB"; then
  bad "C5 no protocols in the product vocabulary" "'amqp' is back; it is a protocol, not a product"
else
  ok "C5 no protocols in the product vocabulary"
fi

echo "=== D: every standing exception carries a reason ==="
if [ ! -f "$ALLOW" ]; then
  ok "D1 no allow-list — nothing to audit"
  ok "D2 no allow-list — nothing to audit"
else
  NOREASON=0
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$line" ] || continue
    case "$line" in
      *"::"*)
        r="${line#*::}"
        r="$(printf '%s' "$r" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$r" ] || NOREASON=$((NOREASON+1))
        ;;
      *) NOREASON=$((NOREASON+1)) ;;
    esac
  done < "$ALLOW"
  [ "$NOREASON" -eq 0 ] && ok "D1 every exception has a reason" \
    || bad "D1 every exception has a reason" "$NOREASON without one"
  # An allow-list longer than the thing it excuses is not an allow-list, it is an off switch.
  NENT="$(grep -cE '^[^#[:space:]].*::' "$ALLOW" 2>/dev/null || echo 0)"
  if [ "$NENT" -le 12 ]; then
    ok "D2 the allow-list is bounded ($NENT entries)"
  else
    bad "D2 the allow-list is bounded" "$NENT entries — at this size the gate is off, not configured"
  fi
fi

echo ""
printf 'tier1-generic: %d ok, %d failed\n' "$PASS" "$FAIL"
# run-tests.sh calls a suite that exits 0 without this line UNMEASURED, not passed.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
