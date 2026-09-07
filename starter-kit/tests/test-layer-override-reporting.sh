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
# REPOINTED 2026-09-07. This was $T2T/templates/tier3-instance - the org layer's OWN
# copy of the instance kit, deleted when Tier 1's starter-kit/instance/ became the single
# Tier-3 generator (operator decision: "T1"). The fixture is "the tier-3 installer this
# repo ships"; only which file that is has moved.
T3T="$KIT/instance"
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
    notRestorable:{"gh auth login":"credentials cannot live in a lockfile"} }' > "$d/loom.lock.json"
}

run_t3()  { ( cd "$1" && CLAUDE_HOME="$1/live" bash install.sh --offline 2>&1 ); }
run_t2()  { ( cd "$1" && CLAUDE_HOME="$2" bash install.sh --offline --no-verify 2>&1 ); }

# ⚠️ CASES A, B AND C WERE HERE AND ARE DELETED, 2026-09-07 — MOVED, NOT DROPPED.
# They were the TIER-3 half of this suite: that an instance installing over a layer names
# every override (A), that a re-run re-reports only the REAL ones (B), and that zero
# overrides are still counted out loud (C). All three drove the org layer's own copy of the
# instance installer, which is deleted — Tier 1's starter-kit/instance/ is now the single
# Tier-3 generator, and it reports overrides through boot-kit/scripts/rehydrate.sh.
#
# ⚠️ THE COVERAGE MOVED TO THE SUITE THAT TESTS THE CORRECT INSTALLER, and it is stronger
# there: starter-kit/instance/tests/test-instance-org-delegate.sh asserts the skill override
# reported by name (F1), the hook override by name (G1), that the instance's OWN hook is not
# re-reported on a second identical run (H1), and that the layer-owned one still is (H2) —
# which is case B's negative/positive pair intact. rehydrate.sh additionally distinguishes a
# destructive override from a reversible symlink repoint, which the deleted copy did not.
#
# ⚠️ THE VOCABULARY CHANGED WITH THE OWNER: the copy printed "<name> OVERRIDES a Tier 2
# skill"; rehydrate.sh prints "OVERRIDE <name> ...". Rewriting these three cases against the
# new wording would have duplicated assertions another suite already makes, in a file whose
# subject is the TIER-2 installer. What remains below is exactly that: D, E and F, the tier-2
# half, which is this suite's own subject and is untouched.
#
# Recorded rather than silently removed, because a deleted test and a moved test look
# identical in a diff — and this suite's own header exists because nothing asserted on an
# override message at all.

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
