#!/usr/bin/env bash
# test-p8-waiver-set-arithmetic.sh — prove a P8 waiver actually subtracts.
#
# P8's three set operations are `comm` over two `sort`ed lists. That is only correct if
# sort and comm agree on the order, and under a UTF-8 locale they do NOT agree about
# lines that begin with punctuation or a space — the collation ignores the leading
# character where comm's merge does not. Landmark tokens look exactly like that
# (` acme`, `|acme|`, "`acme."), so comm printed "input is not in sorted order" and
# silently returned the wrong set.
#
# Measured on the real repo before the fix: 22 published landmarks, 5 waivers, all 5
# present — and the subtraction returned 21 unwaived instead of 17. FOUR reasoned
# waivers did not apply, so P8 re-reported findings an operator had explicitly accepted.
# Nothing was lost in the unsafe direction, but a waiver that stops working is how a
# gate becomes the thing people route around, which is the one failure the waiver
# mechanism exists to prevent.
#
# This builds its OWN repo, its OWN bare remote and its OWN landmark config with
# FICTIONAL patterns under $TMPDIR. Committing a real landmark to prove P8 would create
# the exact condition P8 exists to detect, and no later scan could undo it.
#
# Usage: bash boot-kit/scripts/tests/test-p8-waiver-set-arithmetic.sh
# Exit:  0 = the waiver subtracts and comm is quiet   1 = it does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
GATE_SRC="$SCRIPTS/publish-gate.sh"
EXAMPLE="$SCRIPTS/landmarks.example.conf"
[ -f "$GATE_SRC" ] || { echo "no publish-gate.sh at $GATE_SRC"; exit 2; }
[ -f "$EXAMPLE" ] || { echo "no landmarks.example.conf at $EXAMPLE"; exit 2; }

FAIL=0
CHECKS=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/p8waiver.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ok() { CHECKS=$((CHECKS + 1)); echo "  ok   $1"; }
no() { CHECKS=$((CHECKS + 1)); FAIL=1; echo "  FAIL $1"; }

# Five fictional tokens. The first three carry the leading punctuation or space that makes
# sort and comm disagree — that shape IS the subject of this test, not incidental.
T_SPACE=' zeta-corp'
T_TICK='`zeta-corp.'
T_PIPE='|zeta-corp|'
T_PAREN='(zeta-corp-'
T_PLAIN='zeta-widget'
T_OTHER='quux-registry'

REPO="$WORK/repo"
BARE="$WORK/repo.git"
mkdir -p "$REPO/boot-kit/scripts"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name test
cp "$GATE_SRC" "$REPO/boot-kit/scripts/publish-gate.sh"

# A config whose ONLY landmark pattern is our five fictional tokens, and which waives
# three of them with reasons (a waiver with no reason is refused by design).
CONF="$WORK/landmarks.conf"
{
  printf "P1_PATTERN='%s'\n" ' zeta-corp|`zeta-corp\.|\|zeta-corp\||\(zeta-corp-|zeta-widget|quux-registry'
  printf "P2_PATTERN='%s'\n" 'zzz-no-match-p2'
  printf "P3_PATTERN='%s'\n" 'zzz-no-match-p3'
  printf "P4_PATTERN='%s'\n" 'zzz-no-match-p4'
  printf "P5_PATTERN='%s'\n" 'zzz-no-match-p5'
  printf "P6_PATTERN='%s'\n" 'zzz-no-match-p6'
  printf "P7_PATTERN='%s'\n" 'zzz-no-match-p7'
  printf "P1_CANARY='%s'\n" ' zeta-corp canary'
  printf "P8_WAIVED='\n"
  printf "%s\tfictional test token, waived so this suite can prove subtraction works\n" "\`zeta-corp."
  printf "%s\tfictional test token, waived so this suite can prove subtraction works\n" "|zeta-corp|"
  printf "%s\tfictional test token, waived so this suite can prove subtraction works\n" "(zeta-corp-"
  printf "%s\tthis one CANNOT take effect - see the whitespace assertion below\n" " zeta-corp"
  printf "'\n"
} > "$CONF"

# Publish all five tokens, so every waiver has something to subtract.
{
  echo "line one mentions$T_SPACE here"
  echo "line two mentions $T_TICK here"
  echo "line three mentions $T_PIPE here"
  echo "line four mentions $T_PAREN here"
  echo "line five mentions $T_PLAIN here"
  echo "line six mentions $T_OTHER here"
} > "$REPO/docs.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "published landmarks"
git init -q --bare "$BARE"
git -C "$REPO" remote add origin "$BARE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin

OUT="$WORK/out.txt"
ERR="$WORK/err.txt"
DF_LANDMARKS_CONF="$CONF" DF_PUBLISH_GATE_STATUS=0 \
  bash "$REPO/boot-kit/scripts/publish-gate.sh" --history > "$OUT" 2> "$ERR"

# The unwaived list is printed between a header and the remedy lines. note() prefixes
# exactly 8 spaces and the token loop adds 2, so strip a FIXED width of 10 — stripping
# leading whitespace with a greedy sed would destroy the leading space of the very token
# the whitespace assertion below is about, and the suite would then blame the gate for its
# own harness. (It did, once, before this line was written this way.)
UNW="$WORK/unwaived.txt"
sed -n '/unwaived landmark token(s)/,/a working-tree deletion will NOT fix/p' "$OUT" \
  | sed '1d;$d' | cut -c11- > "$UNW"

echo "P8 waiver set arithmetic"

# 1-3. Each waived token must NOT be reported as an unwaived finding. These three all
# begin with punctuation, which is the shape that made sort and comm disagree.
for t in "$T_TICK" "$T_PIPE" "$T_PAREN"; do
  if grep -qxF -- "$t" "$UNW"; then
    no "waived token is still reported as unwaived: [$t]"
  else
    ok "waived token subtracted: [$t]"
  fi
done

# 4. A SEPARATE, PRE-EXISTING LIMIT, pinned here because this suite is where it surfaced
# and it would otherwise read as a waiver that mysteriously does nothing. The waiver line
# is parsed as "<token><whitespace><reason>" via ${wline%%[[:space:]]*}, so a landmark whose
# matched TEXT begins with whitespace yields an EMPTY token and the waiver is skipped — such
# a finding cannot be waived at all. Real configs do carry space-padded patterns, whose
# matched text looks exactly like this. Reported separately; not changed here, because the
# waiver file format is part of a security control and widening it is its own decision.
if grep -qxF -- "$T_SPACE" "$UNW"; then
  ok "a whitespace-leading token is NOT waivable, and is still reported (known limit)"
else
  no "a whitespace-leading token vanished — either it became waivable (tell the author, the"
  no "  assertion above is now wrong) or a real finding is being dropped: [$T_SPACE]"
fi

# 5-6. The two tokens that were NOT waived must still be reported — otherwise this
# suite would pass just as well against a gate that reports nothing at all.
for t in "$T_PLAIN" "$T_OTHER"; do
  if grep -qxF -- "$t" "$UNW"; then
    ok "unwaived token still reported: [$t]"
  else
    no "unwaived token went missing — the gate is dropping real findings: [$t]"
  fi
done

# 7. comm must not complain. The warning is the tell that the set arithmetic is unsound,
# and it goes to stderr where a passing exit code hides it.
if grep -q 'not in sorted order' "$ERR"; then
  no "comm reported unsorted input — the set arithmetic is unsound"
else
  ok "comm did not report unsorted input"
fi

echo "ASSERTIONS: $CHECKS"
if [ "$FAIL" -ne 0 ]; then
  echo "P8 waiver arithmetic is broken" >&2
  exit 1
fi
exit 0
