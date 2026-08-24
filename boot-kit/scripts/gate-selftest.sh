#!/usr/bin/env bash
# gate-selftest.sh — prove publish-gate.sh actually FIRES.
#
# Every gate failure this repo has had was the same shape: a check that reported PASS
# without being able to catch anything, and had never once been run against an input it
# must catch.
#
#   P3 matched infra ids but never the product name  -> CLEAN on 29 landmark hits
#   P2 used `\bmrn\b`; git grep -E has no PCRE, so    -> matched zero lines, ever
#      `\b` compiles fine and matches nothing
#   P8 reused P3's patterns                           -> inherited P3's blind spot
#
# A passing gate proves nothing. This script plants a known-positive canary for every
# pattern class and asserts the gate FAILS on each. Run it after ANY change to
# landmarks.conf or to the gate.
#
# Usage: bash boot-kit/scripts/gate-selftest.sh [--show]
#        --show  print the text of each unpinned branch. Off by default: the landmark
#                config is a list of the exact nouns that must not be published, and a
#                report that echoes one to say it is untested turns the instrument into
#                the leak.
# Exit:  0 = every class fires   1 = at least one class is INERT
#
# BRANCH COVERAGE, added 2026-08-24. "Every class fires" was the whole verdict, and it is
# not the whole question. A pattern is an ALTERNATION OF BRANCHES; a canary proves exactly
# one of them; the score was printed per CLASS. Measured on 2026-08-24, the real config
# held 63 branches pinned by 11 canaries — 12 of 63 — and this script printed `all 7
# classes fire`. Deleting fourteen of P4's fifteen branches would not have moved that
# line. (The ticket estimated ~61 from a naive count of `|`; that is the number this
# splitter deliberately does not produce, and the gap between them is the point.) A scan that pins a
# sixth of what it covers looks IDENTICAL to one that pins all of it unless it says so, so
# now it says so — per class, and on the summary line, where a reader who reads one line
# sees it.
#
# This is a REPORT, not a new failure mode, and deliberately so. One canary per branch is
# not the fix: sixty-odd canaries is a maintenance burden that rots, and deriving a canary
# from each branch re-derives the config from itself, which is the circularity that made
# a green self-test meaningless in the first place. Requirement-first coverage is
# gate-reqtest.sh's job. This number's job is to stop the green from overclaiming.
set -uo pipefail

SHOW=0
for arg in "$@"; do
  case "$arg" in
    --show) SHOW=1 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/../.." && pwd)"
GATE="$SELF/publish-gate.sh"
CANARY="$REPO/docs/.gate-selftest-canary.md"

cleanup() { rm -f "$CANARY"; }
trap cleanup EXIT

FAIL=0

# Canaries come from the SAME local config as the patterns. They are not hardcoded here,
# because a canary is by definition a string the patterns must match — hardcoding real
# ones in this committed script would publish the exact nouns the patterns exist to hide.
# That is not hypothetical: this script's first version did precisely that, and an
# independent blob scan caught it.
LANDMARKS="$SELF/landmarks.conf"
[ -f "$LANDMARKS" ] || LANDMARKS="$SELF/landmarks.example.conf"
[ -f "$LANDMARKS" ] || { echo "no landmark config found"; exit 2; }
# shellcheck source=/dev/null
. "$LANDMARKS"

# Indirect expansion of a config variable by NAME. Used for both canaries and patterns —
# bash 3.2 has no `${!name}` for this that also survives `set -u` on an unset var.
var_value() {
  eval "printf '%s\n' \"\${$1:-}\""
}

# Every canary variable the config defines for a class: P1_CANARY plus any P1_CANARY_*.
# ONE canary per class was the bar until 2026-08-10, and it is not enough. A pattern is an
# alternation of BRANCHES, and a single canary proves exactly one branch fires while saying
# nothing about the rest. P1 had four branches and one canary — the three untested ones were
# the client's product name, its repo prefix and its GitHub org, and the gate PASSED on a
# line containing all three. Suffixed canaries make each branch provable, and a config that
# adds a branch without a canary now shows up as an untested branch rather than as a green.
# `set` dumps every shell variable WITH ITS VALUE, and on 2026-08-24 that made this line
# emit `sed: RE error: illegal byte sequence` in a repo whose environment carried a byte
# invalid in the current locale — a canary silently dropped from the list is a class
# silently unproven, which is this script's own failure mode turned on itself. compgen -v
# lists variable NAMES only, so no value is ever fed to a regex engine.
canaries_for() {
  compgen -v | grep -E "^${1}_CANARY[A-Z0-9_]*$" | sort -u
}

# The classes to test come from the CONFIG, not from a hardcoded P1..P7 written here.
# Same reasoning as the suffixed canaries below, one level up: a class the config defines
# and the gate never scans protects nothing, and a self-test walking its own fixed list
# cannot see it — it would report full coverage of seven classes while an eighth sat
# inert. Discovered from the config, that class shows up with no verdict line and fails.
classes_in_config() {
  compgen -v | sed -n 's/^P\([0-9][0-9]*\)_PATTERN$/\1/p' | sort -un | sed 's/^/P/'
}

# Split an ERE on its TOP-LEVEL '|' only. The obvious implementation — split on every '|'
# — is wrong in both directions that matter: a '|' inside a group alternates the GROUP,
# and a '|' inside a bracket expression is a literal character. Both inflate the branch
# count, and a denominator that is too large reports worse coverage than the config has.
# A wrong number in the safe direction is still a wrong number, and it teaches the reader
# to skip the line. Backslash escapes are honoured; a ']' immediately after '[' or '[^' is
# literal, per POSIX, so `[]]` and `[^]]` do not close early.
split_branches() {
  local pat="$1" i=0 n=${#pat} depth=0 inbr=0 brpos=0 cur='' ch k rest skip
  while [ "$i" -lt "$n" ]; do
    ch="${pat:i:1}"
    if [ "$ch" = '\' ] && [ $((i+1)) -lt "$n" ]; then
      cur="$cur$ch${pat:i+1:1}"; i=$((i+2)); continue
    fi
    if [ "$inbr" -eq 1 ]; then
      # A POSIX class/collating/equivalence element — [:digit:], [.a.], [=e=] — nests one
      # more `]` inside the bracket. Closing on it would end the bracket early and let a
      # later '|' read as a top-level branch. No pattern in this repo does that today;
      # the counter is the deliverable here, so it is correct rather than correct by luck.
      if [ "$ch" = '[' ] && case "${pat:i+1:1}" in ':'|'.'|'=') true ;; *) false ;; esac; then
        k="${pat:i+1:1}"
        rest="${pat:i+2}"; skip="${rest%%$k]*}"
        if [ "$skip" != "$rest" ]; then
          cur="$cur[$k$skip$k]"; i=$((i+4+${#skip})); continue
        fi
      fi
      [ "$ch" = ']' ] && [ "$i" -gt "$brpos" ] && inbr=0
      cur="$cur$ch"; i=$((i+1)); continue
    fi
    case "$ch" in
      '[') inbr=1; brpos=$((i+1)); [ "${pat:i+1:1}" = '^' ] && brpos=$((i+2)) ;;
      '(') depth=$((depth+1)) ;;
      ')') [ "$depth" -gt 0 ] && depth=$((depth-1)) ;;
      '|') if [ "$depth" -eq 0 ]; then printf '%s\n' "$cur"; cur=''; i=$((i+1)); continue; fi ;;
    esac
    cur="$cur$ch"; i=$((i+1))
  done
  printf '%s\n' "$cur"
}

echo "=== gate self-test: every pattern class must FAIL on every canary ==="
echo ""

CLASSES="$(classes_in_config)"
[ -n "$CLASSES" ] || { echo "no P*_PATTERN in the landmark config — nothing to prove"; exit 2; }
NCLASS="$(printf '%s\n' "$CLASSES" | grep -c .)"

for class in $CLASSES; do
  vars="$(canaries_for "$class")"
  if [ -z "$vars" ]; then
    printf 'ERROR %s has no %s_CANARY in the landmark config — cannot prove it fires\n' "$class" "$class"
    FAIL=1
    continue
  fi
  for v in $vars; do
    val="$(var_value "$v")"
    [ -n "$val" ] || continue
    printf '%s\n' "$val" > "$CANARY"
    out="$(bash "$GATE" 2>&1 | grep -E "^(PASS|FAIL) +${class} " || true)"
    rm -f "$CANARY"

    case "$out" in
      FAIL*) printf 'ok    %-22s fires\n' "$v" ;;
      PASS*) printf 'INERT %-22s did NOT fire — that branch protects nothing\n' "$v"; FAIL=1 ;;
      *)     printf 'ERROR %-22s produced no verdict line (gate broken?)\n' "$v"; FAIL=1 ;;
    esac
  done
done

echo ""
echo "--- branch coverage: how much of each pattern the canaries above actually reach ---"
echo ""

TOT_BRANCHES=0
TOT_PINNED=0
for class in $CLASSES; do
  pat="$(var_value "${class}_PATTERN")"
  vars="$(canaries_for "$class")"
  nbr=0; npin=0; unpinned=''
  while IFS= read -r br; do
    nbr=$((nbr+1))
    hit=0
    # An EMPTY branch (`a||b`) is left unpinned on purpose. `grep -E ''` matches every
    # line, so probing it would report it as pinned — and an empty branch makes the whole
    # pattern match everything, which is the loudest possible defect wearing a green.
    if [ -n "$br" ]; then
      for v in $vars; do
        val="$(var_value "$v")"
        [ -n "$val" ] || continue
        if printf '%s\n' "$val" | grep -qEi -- "$br" 2>/dev/null; then hit=1; break; fi
      done
    fi
    if [ "$hit" -eq 1 ]; then
      npin=$((npin+1))
    elif [ "$SHOW" -eq 1 ]; then
      unpinned="$unpinned #$nbr=$br"
    else
      unpinned="$unpinned #$nbr"
    fi
  done <<COVEOF
$(split_branches "$pat")
COVEOF
  ncan="$(printf '%s\n' "$vars" | grep -c . || true)"
  TOT_BRANCHES=$((TOT_BRANCHES+nbr))
  TOT_PINNED=$((TOT_PINNED+npin))
  if [ "$npin" -eq "$nbr" ]; then
    printf '  %-4s %3d branches  %2d canaries  %3d pinned  — every branch reached\n' \
      "$class" "$nbr" "$ncan" "$npin"
  else
    printf '  %-4s %3d branches  %2d canaries  %3d pinned  %3d UNPINNED %s\n' \
      "$class" "$nbr" "$ncan" "$npin" "$((nbr-npin))" "$unpinned"
  fi
done

echo ""
printf '  %d of %d pattern branches pinned by %d canaries across %d classes\n' \
  "$TOT_PINNED" "$TOT_BRANCHES" "$(for c in $CLASSES; do canaries_for "$c"; done | grep -c . || true)" "$NCLASS"
if [ "$TOT_PINNED" -lt "$TOT_BRANCHES" ] && [ "$SHOW" -eq 0 ]; then
  echo "  (re-run with --show to see the unpinned branches themselves — masked by default)"
fi

echo ""
# The gate must also be CLEAN with no canary present, or "it fires" is meaningless —
# a gate that fails on everything is as useless as one that passes on everything.
base="$(bash "$GATE" 2>&1 | grep -E '^=== RESULT:' || true)"
case "$base" in
  *CLEAN*) echo "ok    baseline is CLEAN with no canary present" ;;
  *)       echo "ERROR baseline is not clean: $base"; FAIL=1 ;;
esac

echo ""
# The coverage figure belongs ON the verdict line, not only in the table above it. A
# reader who reads one line of this output reads this one, and for six months it said
# `all 7 classes fire` about a config where five sixths of the branches had never been
# tried. A per-class table nobody scrolls to is the same defect one indent deeper.
COV="$TOT_PINNED of $TOT_BRANCHES pattern branches pinned"
if [ "$FAIL" -eq 0 ]; then
  echo "=== SELF-TEST PASSED — all $NCLASS classes fire, baseline clean; $COV ==="
else
  echo "=== SELF-TEST FAILED — at least one class is inert. Do NOT trust a CLEAN result. ($COV) ==="
fi
exit "$FAIL"
