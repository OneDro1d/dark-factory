#!/usr/bin/env bash
# test-do-not-stall.sh — an autonomous loop must be told to KEEP GOING, not only to stop.
#
# WHY THIS EXISTS. The stance shipped here states one half of the attention contract at
# length: do not spend the operator's attention on a question the toolchain can answer.
# It never stated the other half. On 2026-08-25 an orchestrator finished its work and then
# simply stopped — twice in one day — with the queue non-empty and nothing blocking it, and
# the operator had to ask "are you waiting on something?" both times. The distilled record
# of that behaviour is at four recurrences.
#
# Over-asking and stalling are the SAME failure pointed in opposite directions: both hand
# the operator a decision that had already been delegated. A stance that forbids only one of
# them is not a stance, it is a bias — and the bias it produces is the expensive one,
# because a stalled loop is silent and an over-asking loop at least says something.
#
# THE COUNTERWEIGHT IS PART OF THE RULE, not a caveat on it. "Keep working" on its own is
# worse than saying nothing: it is exactly the sentence a model quotes to itself while
# reasoning past a hard stop. So R3 asserts that neither file may carry the keep-going half
# without the stopping half still standing beside it in the same file. Both directions, or
# neither.
#
# Run:  bash boot-kit/scripts/tests/test-do-not-stall.sh
# Exit: 0 all pass · 1 at least one failed. Prints a literal assertion count, because a
# suite that says "ok" without saying how many assertions ran cannot be told from one that
# ran none.
#
#   R1  the rendered iteration prompt carries the clause. This is the ONE file a headless
#       iteration is guaranteed to read — it runs with user-level skills unregistered, so a
#       doctrine that lives only in a skill file is a doctrine that iteration never sees.
#   R2  the shipped operating stance carries it too, as a named failure mode. The prompt is
#       read by headless runs; the stance is read by attended ones. Either alone leaves a
#       whole class of session uncovered.
#   R3  in BOTH files the counterweight still stands: the prompt still refuses to let an
#       authorised decision be escalated AND still renders its hard stops; the stance still
#       enumerates hard stops and still says permission is per action.
#   R4  the clause is SPECIFIC, not an exhortation. It must name the equivalence — that
#       stalling costs the operator's attention the same way over-asking does. "Keep going"
#       passes a loose grep and teaches nothing; the equivalence is what makes the rule
#       decidable at the moment it matters.
#
# Every rule is exercised in BOTH directions, ONE AT A TIME. A batch of assertions added
# together and seen to fail together proves the batch, not each member — so each violation
# below is planted alone, into a scratch COPY of the tree, and the suite must fail for that
# reason and no other. Nothing is ever planted into the tracked tree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

PROMPT_REL="boot-kit/scripts/df-render-prompt.py"
STANCE_REL="skills/work-autonomously/SKILL.md"
SELF_REL="boot-kit/scripts/tests/test-do-not-stall.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# A rule is checked as a CONJUNCTION of independent phrases rather than as one long literal
# string. A single long grep is brittle against reflow — a line rewrap breaks it and the
# doctrine is still there — and it is also too easy to satisfy by pasting the string
# somewhere it does nothing. Each phrase below is a separate claim about the text.
#
# This is not a hypothetical. The first draft of R3 grepped for the whole sentence "do not
# mark BLOCKED for a decision you are authorised to make" and went RED on a tree that
# contained it — the sentence wraps across two lines and grep is line-oriented. A false RED
# is cheap; the same mistake in a rule that had ALREADY passed would have been a check
# silently keyed to a line break. Every phrase below therefore fits inside one line.
has_all() {
  local file="$1"; shift
  local phrase
  for phrase in "$@"; do
    grep -qiE -- "$phrase" "$file" || return 1
  done
  return 0
}

run_suite() {
  local root="$1" label="$2"
  local p=0 f=0
  local _PASS=$PASS _FAIL=$FAIL
  PASS=0; FAIL=0
  local saved_root="$ROOT"; ROOT="$root"

  local prompt="$ROOT/$PROMPT_REL" stance="$ROOT/$STANCE_REL"

  # ---- R1 the rendered prompt carries the clause --------------------------------------
  if [ ! -f "$prompt" ]; then
    bad "R1 $PROMPT_REL does not exist"
  elif has_all "$prompt" 'do not stall' 'queued' 'do it now'; then
    ok "R1 $PROMPT_REL carries the do-not-stall clause (queued-work check + act now)"
  else
    bad "R1 $PROMPT_REL has no do-not-stall clause — a headless iteration reads this file and no skill"
  fi

  # ---- R2 the shipped stance carries it as a named failure mode -----------------------
  if [ ! -f "$stance" ]; then
    bad "R2 $STANCE_REL does not exist"
  elif has_all "$stance" 'stalling' 'queued' 'do it now'; then
    ok "R2 $STANCE_REL names stalling on queued work as a failure mode"
  else
    bad "R2 $STANCE_REL states the over-asking half only — the under-acting half is missing"
  fi

  # ---- R3 the counterweight still stands, in both files -------------------------------
  # An orphaned keep-going clause is the failure this rule exists to prevent, so it is
  # asserted per file rather than globally: a stop list in the OTHER file protects nothing.
  if [ ! -f "$prompt" ]; then
    bad "R3 $PROMPT_REL does not exist"
  elif has_all "$prompt" 'do not mark BLOCKED' 'authorised to make' '\{stops\}'; then
    ok "R3 $PROMPT_REL still refuses escalation of an authorised decision AND still renders its stops"
  else
    bad "R3 $PROMPT_REL lost its counterweight — keep-going without the stops beside it is worse than silence"
  fi

  if [ ! -f "$stance" ]; then
    bad "R3 $STANCE_REL does not exist"
  elif has_all "$stance" '^## Hard stops' 'Permission is'; then
    ok "R3 $STANCE_REL still enumerates hard stops and still says permission is per action"
  else
    bad "R3 $STANCE_REL lost its counterweight — the stops are what make continuing safe"
  fi

  # ---- R4 the clause is specific, not an exhortation ----------------------------------
  # The load-bearing content is the EQUIVALENCE. Without it the reader has a slogan and no
  # test; with it the reader can decide, at the moment of hesitation, which failure they are
  # about to commit. Asserted in both files because both are read by different runs.
  local eq='same (attention failure|failure).{0,40}(as|than) over-asking|over-asking.{0,60}same (attention failure|failure)'
  local n=0
  local fpath
  for fpath in "$prompt" "$stance"; do
    [ -f "$fpath" ] || continue
    if grep -qiE -- "$eq" "$fpath"; then n=$((n+1)); fi
  done
  if [ "$n" -eq 2 ]; then
    ok "R4 both files state the equivalence (stalling costs attention as over-asking does)"
  else
    bad "R4 only $n/2 files state the equivalence — an exhortation without it is a slogan, not a rule"
  fi

  p=$PASS; f=$FAIL
  ROOT="$saved_root"; PASS=$_PASS; FAIL=$_FAIL
  SUITE_PASS=$p; SUITE_FAIL=$f
  printf '%s: %d passed, %d failed\n' "$label" "$p" "$f"
}

echo "== forward pass: the tracked tree must satisfy every rule =="
run_suite "$ROOT" "tracked tree"
FWD_PASS=$SUITE_PASS; FWD_FAIL=$SUITE_FAIL

# Forward-only mode exists solely so the reverse pass can re-exec a planted COPY of this
# script without that copy planting violations of its own, forever.
if [ -n "${DO_NOT_STALL_FORWARD_ONLY:-}" ]; then
  [ "$FWD_FAIL" -eq 0 ] && exit 0 || exit 1
fi

# --------------------------------------------------------------------------------------
# Reverse pass. Each violation is planted ALONE into a scratch copy of the tracked tree and
# the copy's OWN script is re-executed there in forward-only mode, so the child process is
# the unit of isolation and the parent reads only its printed counts and its FAIL lines.
#
# Each plant asserts BOTH that the suite failed AND that the rule it targets is among the
# rules that failed. "Something went red" is not evidence the intended check fired.
# --------------------------------------------------------------------------------------
echo
echo "== reverse pass: each rule must FAIL on the input it exists to catch =="
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/do-not-stall.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

REV_OK=0
REV_BAD=0
plant() {
  local name="$1" want="$2"; shift 2
  local work="$SCRATCH/$name" out="$SCRATCH/$name.out"
  rm -rf "$work"; mkdir -p "$work"
  (cd "$ROOT" && git ls-files -z | tar -cf - --null -T -) | (cd "$work" && tar -xf -)
  ( cd "$work" && "$@" ) >/dev/null 2>&1
  DO_NOT_STALL_FORWARD_ONLY=1 bash "$work/$SELF_REL" >"$out" 2>&1
  local rc=$? fails hit_rules
  fails="$(grep -c '^  FAIL ' "$out" | tr -d ' ')"
  hit_rules="$(grep '^  FAIL ' "$out" | awk '{print $2}' | sort -u | tr '\n' ' ')"
  if [ "$rc" -ne 0 ] && printf '%s' " $hit_rules" | grep -q " $want "; then
    REV_OK=$((REV_OK+1))
    printf '  ok   %-28s caught by %s(%s assertion(s) failed)\n' "$name" "$hit_rules" "$fails"
  else
    REV_BAD=$((REV_BAD+1))
    printf '  FAIL %-28s wanted %s among failures, got: %s(rc=%s)\n' "$name" "$want" "${hit_rules:-none }" "$rc"
  fi
}

# R1/R2: the clause is deleted from one file at a time, so each file's absence is proven to
# fail on its own account rather than under cover of the other's.
plant R1-clause-gone-from-prompt R1 \
  sed -i.bak '/And the mirror of that/,/dissolves one\./d' boot-kit/scripts/df-render-prompt.py
plant R2-clause-gone-from-stance R2 \
  sed -i.bak '/Stalling on work you are already authorised/,+7d' skills/work-autonomously/SKILL.md
# R3: the keep-going half survives but its counterweight is removed — the orphaned-clause
# failure, and the one a reviewer is least likely to notice, because the file still reads
# like doctrine.
plant R3-prompt-loses-stops      R3 \
  sed -i.bak 's|do not mark BLOCKED for a|carry on for a|' boot-kit/scripts/df-render-prompt.py
plant R3-stance-loses-stops      R3 \
  sed -i.bak 's|^## Hard stops|## Things to bear in mind|' skills/work-autonomously/SKILL.md
# R4: the clause degrades to an exhortation. R1/R2 still pass — which is the point: a loose
# grep for "keep working" cannot tell doctrine from a slogan.
plant R4-equivalence-dropped     R4 \
  sh -c "sed -i.bak 's|the same attention failure as over-asking|a bad look|g' boot-kit/scripts/df-render-prompt.py skills/work-autonomously/SKILL.md"

echo
echo "=================================================================="
printf 'forward : %d assertions passed, %d failed\n' "$FWD_PASS" "$FWD_FAIL"
printf 'reverse : %d planted violations caught, %d NOT caught\n' "$REV_OK" "$REV_BAD"
echo "=================================================================="

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted all of these" from "asserted nothing" — both exit 0 — so the count is
# DECLARED. It is the forward assertions PLUS the reverse pass's planted violations,
# because both halves are checks this suite actually executed. Deliberately NOT emitted
# on the FORWARD_ONLY path above: that path is a re-exec of a planted COPY whose output
# is consumed by this script, and a stray count line there would be read as this
# suite's own total.
echo "ASSERTIONS: $((FWD_PASS + FWD_FAIL + REV_OK + REV_BAD))"
if [ "$FWD_FAIL" -eq 0 ] && [ "$REV_BAD" -eq 0 ]; then
  echo "PASS"
  exit 0
fi
echo "FAIL"
exit 1
