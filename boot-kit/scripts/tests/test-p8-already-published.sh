#!/usr/bin/env bash
# test-p8-already-published.sh — prove P8 asks about the LANDMARK, not only the COMMIT.
#
# P8 classifies each COMMIT by reachability (published / pending / local-only) and then
# words each verdict as though it had classified the LANDMARK. Those are not the same
# question. A string that is already public, and that also appears in an unpushed commit,
# lands in the PENDING bucket and collects:
#
#   FAIL  P8 landmark is on HEAD and NOT yet published — the next push would publish it
#
# which is false. The push publishes nothing that is not already fetchable. Worse, the
# prescribed remedy for the sibling PUBLISHED finding is "rebuild from a fresh git init",
# so the false line manufactures pressure toward an IRREVERSIBLE action — orphaning every
# published SHA — to suppress a disclosure that has already happened. That is the same
# failure family as this gate's other four: the check runs, but its verdict describes
# something other than what it measured.
#
# The fix must not buy accuracy by going quiet. The direction that matters is the OTHER
# one: a genuinely new landmark in an unpushed commit MUST still be fatal and MUST still
# say the push would publish it. R2 and R3 exist to fail if the fix over-reaches.
#
# Everything runs in a SCRATCH repo under $TMPDIR. A test that proved this by committing
# a landmark into the real repo would create the exact condition P8 exists to detect.
#
# Usage: bash boot-kit/scripts/tests/test-p8-already-published.sh
# Exit:  0 = every rule holds   1 = at least one does not   2 = could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
GATE_SRC="$SCRIPTS/publish-gate.sh"

# Canaries come from the SAME local config as the patterns, never hardcoded here.
# Hardcoding a real landmark in a committed test publishes the very noun the patterns
# exist to hide — gate-selftest.sh's first version did exactly that.
LANDMARKS="$SCRIPTS/landmarks.conf"
LANDMARKS_SRC=landmarks.conf
[ -f "$LANDMARKS" ] || { LANDMARKS="$SCRIPTS/landmarks.example.conf"; LANDMARKS_SRC=landmarks.example.conf; }
[ -f "$LANDMARKS" ] || { echo "no landmark config found"; exit 2; }
# shellcheck source=/dev/null
. "$LANDMARKS"

# TWO distinct landmarks are required: one to publish and repeat, one that is new.
# P1 and P4 are both inside HIST_PAT (P1..P5), so both are visible to the history scan.
OLD_TEXT="${P1_CANARY:-}"
NEW_TEXT="${P4_CANARY:-}"
[ -n "$OLD_TEXT" ] || { echo "P1_CANARY unset in $LANDMARKS — cannot run"; exit 2; }
[ -n "$NEW_TEXT" ] || { echo "P4_CANARY unset in $LANDMARKS — cannot run"; exit 2; }
[ "$OLD_TEXT" != "$NEW_TEXT" ] || { echo "P1_CANARY and P4_CANARY are identical — cannot tell new from repeat"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/p8pub.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Build a repo with a real bare "remote", so refs/remotes/* is populated the way a real
# clone's is. $1 names the shape; the canary placement is what each rule turns on.
#
#   pending-repeat   OLD is published, then removed, then re-introduced UNPUSHED.
#                    Nothing new reaches the world on the next push.
#   pending-new      OLD is published and removed; NEW appears UNPUSHED and has never
#                    been published anywhere. The push genuinely discloses it.
#   pending-mixed    both of the above at once. Something new IS present, so the fatal
#                    "would publish" verdict must survive.
#   pending-repeat-bulk  The truncation trap, built so ORDER does the work. Twelve files
#                    named a01..a12 carry OLD; one file z.md carries NEW. Both are
#                    published. git grep walks paths in order, so z.md's hit is the 13th
#                    and falls outside hist_grep's `head -10` display cap. The unpushed
#                    commit then repeats NEW. Derive the already-published set from the
#                    capped list and NEW reads as never-published, so the repeat is
#                    reported as fresh exposure.
#
#                    An earlier version published ONE landmark in 14 files and did NOT
#                    catch this: `head -10` truncates hit LINES, and fourteen lines of
#                    the same text still leave that text in the truncated set. Volume
#                    was never the variable — DISTINCTNESS past the cap is.
build() {
  # Declared one per line on purpose. `local a="$1" b="$WORK/$a"` looks equivalent and
  # is not: bash creates every name in the statement UNSET before it runs any of the
  # assignments, so $a is unbound under `set -u` and the whole fixture dies inside a
  # command substitution. Same macOS-bash-3.2 family as the empty-array bug in cf66dd5.
  local kind="$1"
  local d="$WORK/$kind"
  local bare="$WORK/$kind.git"
  local i
  rm -rf "$d" "$bare"; mkdir -p "$d/boot-kit/scripts"
  git init -q -b main "$d"
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name  test
  cp "$GATE_SRC"   "$d/boot-kit/scripts/publish-gate.sh"
  cp "$LANDMARKS"  "$d/boot-kit/scripts/$LANDMARKS_SRC"
  echo clean > "$d/docs.md"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm base

  # --- publish OLD, then remove it from the working tree ---------------------------
  if [ "$kind" = "pending-repeat-bulk" ]; then
    # a01..a12 sort before z.md, so z.md's hit is the 13th and misses the 10-hit cap.
    for i in $(seq -w 1 12); do printf '%s\n' "$OLD_TEXT" > "$d/a$i.md"; done
    printf '%s\n' "$NEW_TEXT" > "$d/z.md"
    git -C "$d" add -A >/dev/null; git -C "$d" commit -qm "publish a x12 and z"
    git -C "$d" rm -q a*.md z.md >/dev/null
  else
    printf '%s\n' "$OLD_TEXT" > "$d/old.md"
    git -C "$d" add -A >/dev/null; git -C "$d" commit -qm "publish old"
    git -C "$d" rm -q old.md >/dev/null
  fi
  git -C "$d" commit -qm "remove old from the tree"

  # Everything so far is what the world can fetch.
  git init -q --bare "$bare"
  git -C "$d" remote add origin "$bare"
  git -C "$d" push -q origin main
  git -C "$d" fetch -q origin

  # --- now the UNPUSHED commit, whose contents are what each rule turns on ----------
  case "$kind" in
    pending-repeat)
      printf '%s\n' "$OLD_TEXT" > "$d/again.md" ;;
    pending-repeat-bulk)
      # NEW_TEXT, not OLD_TEXT: it is the one whose published hit is past the cap.
      printf '%s\n' "$NEW_TEXT" > "$d/again.md" ;;
    pending-new)
      printf '%s\n' "$NEW_TEXT" > "$d/fresh.md" ;;
    pending-mixed)
      printf '%s\n' "$OLD_TEXT" > "$d/again.md"
      printf '%s\n' "$NEW_TEXT" > "$d/fresh.md" ;;
  esac
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm "unpushed"
  printf '%s\n' "$d"
}

run() { bash "$1/boot-kit/scripts/publish-gate.sh" --history 2>&1; }
p8()  { printf '%s\n' "$1" | grep -E '^(PASS|FAIL|WARN) +P8 ' | tr '\n' ';'; }

# Every rule below that asserts the ABSENCE of a string needs this first. An assertion of
# the form "the bad phrase is not present" passes when the gate produced NO output at all —
# which is precisely what happened while build() was crashing: two rules reported ok over a
# fixture that never existed. A negative is only evidence once the instrument is known live.
live() {  # live <verdict-string> <rule-label>
  if [ -n "$1" ]; then
    return 0
  fi
  bad "$2" "CONTROL FAILED: the gate emitted no P8 verdict at all — fixture did not build"
  return 1
}

# ---------------------------------------------------------------------------------
# R1  A pending commit that only REPEATS an already-public landmark must not be told
#     it is about to publish it.
D="$(build pending-repeat)"; OUT="$(run "$D")"; V="$(p8 "$OUT")"
R1="R1 a pending commit repeating a PUBLISHED landmark is not called 'would publish'"
if live "$V" "$R1"; then
  if printf '%s' "$V" | grep -q 'NOT yet published'; then
    bad "$R1" "$V"
  else
    ok "$R1"
  fi
fi

# R1b  Silence is not the fix either. It must still be REPORTED — as a repeat.
#
# This rule was first written as grep -iE 'P8 .*(already[- ]published|repeat)' and it went
# GREEN during the RED run: the "ALREADY PUBLISHED" line it matched is the very line R1b
# exists to be DISTINCT from. An assertion satisfied by the text it is meant to replace
# tests nothing. It must require phrasing only the FIXED gate can produce — a verdict of
# its own, about the PENDING commits, naming them a repeat. `[^;]*` keeps the match inside
# one verdict, since p8() joins them with ';'. A lone green in a red batch is a signal.
if printf '%s' "$V" | grep -qiE 'P8 [^;]*repeat'; then
  ok "R1b the repeat is still reported, in a verdict of its own that names it a repeat"
else
  bad "R1b the repeat is still reported, in a verdict of its own that names it a repeat" "$V"
fi

# R1c  The PUBLISHED finding itself is untouched and still fatal.
if printf '%s' "$V" | grep -q 'FAIL.*ALREADY PUBLISHED'; then
  ok "R1c the PUBLISHED finding is unchanged and still FAIL"
else
  bad "R1c the PUBLISHED finding is unchanged and still FAIL" "$V"
fi

# R1d  Overall verdict stays FINDINGS — the exposure is real, merely already spent.
if printf '%s\n' "$OUT" | grep -q '=== RESULT: FINDINGS'; then
  ok "R1d overall verdict is still FINDINGS — an already-spent exposure is still an exposure"
else
  bad "R1d overall verdict is still FINDINGS" "$(printf '%s\n' "$OUT" | grep '=== RESULT:')"
fi

# ---------------------------------------------------------------------------------
# R2  THE DIRECTION THAT MATTERS. A never-published landmark in a pending commit must
#     still be fatal, and must still say the push would publish it. If the fix bought
#     R1 by going quiet, this is where it shows.
D="$(build pending-new)"; OUT="$(run "$D")"; V="$(p8 "$OUT")"
if printf '%s' "$V" | grep -q 'FAIL.*NOT yet published'; then
  ok "R2 a genuinely NEW landmark on HEAD is still FAIL 'the next push would publish it'"
else
  bad "R2 a genuinely NEW landmark on HEAD is still FAIL 'the next push would publish it'" "$V"
fi

# ---------------------------------------------------------------------------------
# R3  Mixed: a repeat AND something new in the same pending set. One new landmark is
#     enough to earn the fatal verdict; the repeat must not launder it.
D="$(build pending-mixed)"; OUT="$(run "$D")"; V="$(p8 "$OUT")"
if printf '%s' "$V" | grep -q 'FAIL.*NOT yet published'; then
  ok "R3 a repeat alongside something NEW does not launder the new one"
else
  bad "R3 a repeat alongside something NEW does not launder the new one" "$V"
fi

# ---------------------------------------------------------------------------------
# R4  The truncation trap. hist_grep caps its DISPLAY at 10 hits. If the already-
#     published set is derived from that capped list, a repeat of the 11th..14th hit
#     reads as new. Publish 14 and repeat one.
D="$(build pending-repeat-bulk)"; OUT="$(run "$D")"; V="$(p8 "$OUT")"
R4="R4 already-published is computed from UNTRUNCATED output, not the 10-hit display"
if live "$V" "$R4"; then
  # The positive control is sharper here than mere non-emptiness: this fixture MUST also
  # produce the PUBLISHED finding, or the 14 published hits never happened and the
  # truncation trap is not being exercised at all.
  if ! printf '%s' "$V" | grep -q 'ALREADY PUBLISHED'; then
    bad "$R4" "CONTROL FAILED: no PUBLISHED finding — the 14-hit fixture did not build"
  elif printf '%s' "$V" | grep -q 'NOT yet published'; then
    bad "$R4" "$V"
  else
    ok "$R4"
  fi
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
