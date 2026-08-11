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
# Usage: bash boot-kit/scripts/gate-selftest.sh
# Exit:  0 = every class fires   1 = at least one class is INERT
set -uo pipefail

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

canary_for() {
  eval "printf '%s\n' \"\${$1:-}\""
}

# Every canary variable the config defines for a class: P1_CANARY plus any P1_CANARY_*.
# ONE canary per class was the bar until 2026-08-10, and it is not enough. A pattern is an
# alternation of BRANCHES, and a single canary proves exactly one branch fires while saying
# nothing about the rest. P1 had four branches and one canary — the three untested ones were
# the client's product name, its repo prefix and its GitHub org, and the gate PASSED on a
# line containing all three. Suffixed canaries make each branch provable, and a config that
# adds a branch without a canary now shows up as an untested branch rather than as a green.
canaries_for() {
  set | sed -n "s/^\(${1}_CANARY[A-Z_]*\)=.*/\1/p" | sort -u
}

echo "=== gate self-test: every pattern class must FAIL on every canary ==="
echo ""

for class in P1 P2 P3 P4 P5 P6 P7; do
  vars="$(canaries_for "$class")"
  if [ -z "$vars" ]; then
    printf 'ERROR %s has no %s_CANARY in the landmark config — cannot prove it fires\n' "$class" "$class"
    FAIL=1
    continue
  fi
  for v in $vars; do
    val="$(canary_for "$v")"
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
# The gate must also be CLEAN with no canary present, or "it fires" is meaningless —
# a gate that fails on everything is as useless as one that passes on everything.
base="$(bash "$GATE" 2>&1 | grep -E '^=== RESULT:' || true)"
case "$base" in
  *CLEAN*) echo "ok    baseline is CLEAN with no canary present" ;;
  *)       echo "ERROR baseline is not clean: $base"; FAIL=1 ;;
esac

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "=== SELF-TEST PASSED — all 7 classes fire, baseline clean ==="
else
  echo "=== SELF-TEST FAILED — at least one class is inert. Do NOT trust a CLEAN result. ==="
fi
exit "$FAIL"
