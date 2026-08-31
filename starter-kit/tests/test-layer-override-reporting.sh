#!/usr/bin/env bash
# test-layer-override-reporting.sh — when one layer installs over another, it says so.
#
# WHAT THIS PINS, AND WHY IT IS ITS OWN SUITE. `test-org-layer-shape.sh` pins how the two
# template installers READ a lockfile. This pins what they do when two layers claim the
# same name — a different claim, and one that was wrong in three places at once:
#
#   1. The tier-3 template reported a hook override by TESTING EXISTENCE. A hook is
#      COPIED, so a file at that path proves only that some earlier run put one there —
#      including the same installer's own previous run. It therefore fired on every
#      re-install. This is the failure mode that matters most here, because it is not a
#      missing warning but a WRONG one, and a warning that is wrong every second time
#      trains the reader past the one that is right.
#   2. The tier-2 installer said "repointing $s (was …)" for a skill and NOTHING for a
#      hook. The asymmetry meant an org layer could silently overwrite a hook another
#      layer had installed — the exact "silent override" its sibling warns about.
#   3. Both were invisible: nothing anywhere asserted on an override message.
#
# So every case below has a NEGATIVE half. A check that reports nothing at all passes the
# positive assertions of a suite that only looks for silence, and passes the negative
# assertions of one that only looks for noise. Only both together pin the behaviour.
#
# Usage: bash starter-kit/tests/test-layer-override-reporting.sh
# Exit:  0 = every case behaves   1 = at least one does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T1="$(cd "$SELF/../.." && pwd)"
KIT="$T1/starter-kit"
T2T="$KIT/templates/tier2-org"
T3T="$T2T/templates/tier3-instance"
for f in "$T2T/install.sh" "$T3T/install.sh"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ovrep.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

contains() { case "$3" in *"$2"*) PASS=$((PASS+1)); echo "  ok   $1" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL $1 -- '$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) FAIL=$((FAIL+1)); echo "  FAIL $1 -- '$2' unexpectedly in output" ;;
  *) PASS=$((PASS+1)); echo "  ok   $1" ;; esac; }
slurp()    { cat "$1" 2>/dev/null || printf '<<no such file: %s>>' "$1"; }

# A scratch Tier-2 org layer that owns one skill and one hook of its own.
mk_layer() { # mk_layer <dir>
  local d="$1"
  mkdir -p "$d/skills/shared-skill" "$d/hooks" "$d/vendor"
  echo 'ORG COPY'                        > "$d/skills/shared-skill/SKILL.md"
  printf 'ORG HOOK home=__HOME__\n'      > "$d/hooks/shared.sh"
  cp "$T2T/install.sh" "$d/install.sh"
  jq -n '{ orgLayer:"scratch", orgDisplay:"Scratch", repo:"scratch/layer",
    upstreams:{}, vendorDir:"vendor",
    install:{ skills:["shared-skill"], skillSources:{"shared-skill":"local:skills/shared-skill"},
              hooks:["shared.sh"],     hookSources:{"shared.sh":"local:hooks/shared.sh"} },
    notRestorable:{"gh auth login":"credentials cannot live in a lockfile"} }' > "$d/org.lock.json"
}

# A tier-3 instance that declares the SAME two names, plus one the layer never touches.
mk_instance() { # mk_instance <dir>
  local d="$1"
  mkdir -p "$d/skills/shared-skill" "$d/hooks" "$d/vendor/orglayer"
  echo 'INSTANCE COPY'                        > "$d/skills/shared-skill/SKILL.md"
  printf 'INSTANCE HOOK home=__HOME__\n'      > "$d/hooks/shared.sh"
  printf 'MINE ALONE home=__HOME__\n'         > "$d/hooks/my-own.sh"
  mk_layer "$d/vendor/orglayer"
  # --offline at tier 3 requires a real checkout, not just a directory.
  ( cd "$d/vendor/orglayer" && git init -q . ) >/dev/null 2>&1 || true
  cp "$T3T/install.sh" "$d/install.sh"
  jq -n '{ instance:"scratch", agentName:"x", vendorDir:"vendor",
    upstreams:{ orglayer:{ repo:"acme/orglayer", ref:"deadbeef" } },
    install:{ skills:["shared-skill"], skillSources:{"shared-skill":"local:skills/shared-skill"},
              hooks:["shared.sh","my-own.sh"],
              hookSources:{"shared.sh":"local:hooks/shared.sh","my-own.sh":"local:hooks/my-own.sh"} },
    notRestorable:{"gh auth login":"credentials cannot live in a lockfile"} }' > "$d/instance.lock.json"
}

run_t3()  { ( cd "$1" && CLAUDE_HOME="$1/live" bash install.sh --offline 2>&1 ); }
run_t2()  { ( cd "$1" && CLAUDE_HOME="$2" bash install.sh --offline --no-verify 2>&1 ); }

echo "=== A. tier 3 over tier 2: the instance wins, and every override is named ==="
A="$WORK/a"; mk_instance "$A"
OUT="$(run_t3 "$A")"
contains "A1 the skill override is named"      "OVERRIDES a Tier 2 skill" "$OUT"
contains "A2 the instance's skill is the live one" "INSTANCE COPY" "$(slurp "$A/live/skills/shared-skill/SKILL.md")"
contains "A3 the hook override is named"       "OVERRIDES a Tier 2 hook"  "$OUT"
contains "A4 the instance's hook is the live one"  "INSTANCE HOOK" "$(slurp "$A/live/hooks/shared.sh")"
absent   "A5 a name only the instance declares is NOT called an override" "my-own.sh OVERRIDES" "$OUT"

echo "=== B. re-run: only the REAL overrides are reported the second time ==="
# The canary for the check itself. `my-own.sh` exists with byte-identical content on the
# second run, so an existence test reports it and is wrong. `shared.sh` is rewritten by
# the layer on every run, so it must STILL be reported — without that half, an installer
# that reports nothing at all would pass this case.
OUT2="$(run_t3 "$A")"
absent   "B1 the instance's own hook is not re-reported" "my-own.sh OVERRIDES"     "$OUT2"
contains "B2 the layer-owned hook still is"              "OVERRIDES a Tier 2 hook" "$OUT2"
contains "B3 the layer-owned skill still is"             "OVERRIDES a Tier 2 skill" "$OUT2"

echo "=== C. nothing collides: the count is still printed ==="
# "No overrides" and "nobody looked" are different facts and must not render the same.
C="$WORK/c"; mk_instance "$C"
jq '.install.skills = [] | .install.hooks = ["my-own.sh"]
    | .install.hookSources = {"my-own.sh":"local:hooks/my-own.sh"}' \
  "$C/instance.lock.json" > "$C/tmp.json"
mv "$C/tmp.json" "$C/instance.lock.json"
OUT="$(run_t3 "$C")"
contains "C1 zero overrides are still counted out loud" "0 override(s)" "$OUT"
absent   "C2 and nothing is called an override"         "OVERRIDES"     "$OUT"

echo "=== D. tier 2 over another layer: the hook half is no longer silent ==="
D="$WORK/d"; mk_layer "$D"; mkdir -p "$WORK/d-live/hooks" "$WORK/d-live/skills"
printf 'SOMEONE ELSE HOOK\n' > "$WORK/d-live/hooks/shared.sh"
OUT="$(run_t2 "$D" "$WORK/d-live")"
contains "D1 replacing a different copy of a hook is announced" "replacing a different copy of shared.sh" "$OUT"
contains "D2 and the layer's copy is what lands"               "ORG HOOK" "$(slurp "$WORK/d-live/hooks/shared.sh")"

echo "=== E. tier 2 re-run: identical content is not announced ==="
OUT2="$(run_t2 "$D" "$WORK/d-live")"
absent   "E1 the second identical install says nothing" "replacing a different copy" "$OUT2"
contains "E2 control: it did run and install the hook"  "hooks installed"            "$OUT2"

echo "=== F. tier 2's skill half, which was already right, stays right ==="
# Pinned so the fix to the hook half cannot be 'balanced' later by deleting this one.
F="$WORK/f"; mk_layer "$F"; mkdir -p "$WORK/f-live/skills" "$WORK/f-live/hooks"
mkdir -p "$WORK/elsewhere/shared-skill"; echo 'SOMEONE ELSE SKILL' > "$WORK/elsewhere/shared-skill/SKILL.md"
ln -s "$WORK/elsewhere/shared-skill" "$WORK/f-live/skills/shared-skill"
OUT="$(run_t2 "$F" "$WORK/f-live")"
contains "F1 repointing an existing link is announced with its old target" "repointing shared-skill (was" "$OUT"
contains "F2 and the layer's copy is what lands" "ORG COPY" "$(slurp "$WORK/f-live/skills/shared-skill/SKILL.md")"

echo ""
echo "$PASS passed, $FAIL failed"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
