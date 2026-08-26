#!/usr/bin/env bash
# test-lock-verify-l7-shape.sh — L7 must make the same shape judgement the INSTALLERS make.
#
# WHY THIS EXISTS. `install.skills`/`install.hooks` have an older reading: a single MAP of
# name -> source, with no `skillSources`/`hookSources` key. The estate already ruled on it —
# the array+map shape won, both shipped installers REFUSE the map rather than reading it
# (`lock_shape_guard`, starter-kit/templates/tier2-org/install.sh:153-168 and its
# templates/tier3-instance/install.sh:83-98), and boot-kit/scripts/df-lock-migrate.py is the
# one-command fix the refusal names.
#
# L7 — the VERIFIER — never got that guard. jq's `(.install[$k] // [])[]` iterates a map's
# VALUES, so L7 took "upstream:dark-factory/skills/agent-notepad" for a NAME, looked it up in
# an absent skillSources, and reported drift: 50 lines, 46 skills + 4 hooks, every one a
# false positive, on providentiaww/dark-factory-onedroid org.lock.json — the one file that
# decides what the whole minted OneDroid Tier 3 fleet installs. Loud and WRONG is worse than
# silent: it is what teaches a reader to skip the verdict.
#
# THE CONTRACT UNDER TEST IS AGREEMENT, not a message. A lockfile install.sh would refuse
# outright must not verify as LOCKED — a verifier more permissive than the installer is how
# "in sync" comes to mean two different things in one estate. So the cases below assert the
# same three-way classification on both sides, on the SAME fixture:
#
#   array   -> both accept; L7 cross-checks both directions and says how many
#   null    -> both accept; nothing to check is a fact, agreement would be a claim
#   object  -> both REFUSE, empty or not (the guard dies on `object`, and the live
#              tier3 template is `{}` on both keys)
#   other   -> both refuse
#
# THE ASSERTIONS ARE ON THE L7 BLOCK, NEVER ON THE EXIT CODE. A scratch instance drifts on
# L3/L6 by design (nothing vendored), so a suite keyed on exit status would be measuring that
# instead. Same discipline as test-lock-verify-args.sh.
#
# RED BASELINE: 16 of 35 fail against the unfixed script; all 35 pass after. The other 19 are
# controls, array-shape regression guards, and over-correction guards — green either way.
# Two are worth naming because they LOOK like defect assertions and are not: M3 ("map is
# DRIFT") is satisfied by the old code's fifty WRONG drift lines, and M5 by the same
# accident. Only M1/M2/M4/M6/R1/R2 distinguish a correct refusal from a misparse.
#
# Usage: bash boot-kit/scripts/tests/test-lock-verify-l7-shape.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
LV="${LOCK_VERIFY:-$SCRIPTS/lock-verify.sh}"
[ -f "$LV" ] || { echo "missing $LV"; exit 2; }
# The OTHER side of the contract: the installer whose guard L7 must agree with. Resolved
# from the repo root so the test breaks loudly if the template is moved rather than
# silently skipping the agreement cases.
T1ROOT="$(cd "$SCRIPTS/../.." && pwd)"
INST="$T1ROOT/starter-kit/templates/tier2-org/templates/tier3-instance/install.sh"
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in L7 block" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in L7 block" ;; *) ok "$1" ;; esac; }
eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lvl7.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# LOOM_LIVE is pointed at a path that does not exist so L5 cannot match anything on the
# developer's real machine. L7 is the subject; every other level is noise here.
export LOOM_LIVE="$WORK/NO-SUCH-LIVE-DIR"

mk() { # mk <name> <install-json>
  mkdir -p "$WORK/$1"
  jq -n --argjson inst "$2" '{vendorDir:"vendor",upstreams:{},install:$inst}' \
    > "$WORK/$1/loom.lock.json"
  # same bytes under the installer's default name, so both sides judge ONE fixture
  cp "$WORK/$1/loom.lock.json" "$WORK/$1/instance.lock.json"
}

# The four shapes, one directory each.
mk array-good  '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
mk array-fwd   '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{}}'
mk array-rev   '{"skills":[],"skillSources":{},"hooks":[],"hookSources":{"a.sh":"upstream:x/hooks/a.sh"}}'
mk map-shape   '{"$comment":"the live Tier 2 org layer spells it this way","skills":{"agent-notepad":"upstream:dark-factory/skills/agent-notepad"},"hooks":{"a.sh":"upstream:dark-factory/hooks/a.sh"}}'
mk empty-map   '{"skills":{},"hooks":{}}'
mk scalar      '{"skills":[],"skillSources":{},"hooks":"a.sh"}'
mkdir -p "$WORK/no-install"
jq -n '{vendorDir:"vendor",upstreams:{}}' > "$WORK/no-install/loom.lock.json"
cp "$WORK/no-install/loom.lock.json" "$WORK/no-install/instance.lock.json"

# guard <dir> -> "refuse" | "accept": how the SHIPPED installer's shape guard judges the
# same bytes. Deliberately NOT the installer's exit code — a scratch instance fails later
# anyway (no vendor, no Tier 2 to fetch), so rc would report "refuse" for every fixture and
# the agreement cases would pass without measuring anything. The first draft did exactly
# that: three array fixtures "agreed" because the installer died downstream. So this reads
# the guard's OWN two messages, which no later failure emits.
# It is COPIED into the fixture, not run in place: line 18 of that installer is
# `cd "$(dirname "$0")"`, so a copy invoked by absolute path silently reads the TEMPLATE's
# own instance.lock.json and reports on that instead. The first draft did exactly that and
# both controls passed while measuring the wrong file.
guard() {
  local out
  cp "$INST" "$WORK/$1/install.sh"
  out="$( cd "$WORK/$1" && CLAUDE_HOME="$WORK/NO-SUCH-LIVE-DIR" \
          bash ./install.sh --dry-run 2>&1 )"
  case "$out" in
    *"that is the old shape"*|*"has unexpected type"*) printf 'refuse' ;;
    *) printf 'accept' ;;
  esac
}

# l7 <dir> -> echoes just the L7 block (from the [L7] header to the blank line before RESULT)
l7() { ( cd "$WORK/$1" && bash "$LV" --lock=loom.lock.json 2>&1 ) | sed -n '/^\[L7\]/,/^$/p'; }

echo "=== controls — a broken harness must not read as a clean result ==="

if bash -n "$LV" 2>/dev/null; then ok "C1 lock-verify.sh parses"
else bad "C1 lock-verify.sh parses" "bash -n failed"; fi

# C2  the fixtures really are the shapes they claim to be. Without this, every map
#     assertion below could pass because the fixture quietly became an array.
eq "C2 map fixture is an object" object \
   "$(jq -r '.install.skills | type' "$WORK/map-shape/loom.lock.json")"
eq "C2 array fixture is an array" array \
   "$(jq -r '.install.hooks | type' "$WORK/array-good/loom.lock.json")"

# C3  the harness can OBSERVE an L7 drift. If it could not, "no false positive" below
#     would be satisfied by a script that prints nothing at all.
contains "C3 harness can see an L7 DRIFT" "DRIFT L7" "$(l7 array-fwd)"

echo "=== the two array directions still work (regression guard) ==="

B="$(l7 array-good)"
contains "A1 clean array PASSes" "PASS  L7" "$B"
absent   "A2 clean array raises no drift" "DRIFT L7" "$B"

B="$(l7 array-fwd)"
contains "A3 name with no source is caught" "hook:a.sh declared with no hookSources entry" "$B"

B="$(l7 array-rev)"
contains "A4 source with no name is caught" "hook:a.sh has a hookSources entry but is not declared" "$B"

echo "=== the map shape: refused, exactly as the installers refuse it ==="

B="$(l7 map-shape)"

# M1 THE DEFECT ITSELF. jq iterated the map's values, so the SOURCE string was reported
#    as an undeclared NAME. Nothing that looks like a source may appear as a name.
absent "M1 map values are not read as names" "upstream:dark-factory/skills/agent-notepad declared with no" "$B"
absent "M2 map raises no forward-direction drift at all" "declared with no skillSources entry" "$B"

# M3 ...and not by going silent either. The installers refuse this file, so the verifier
#    must not call it locked — and it must name the field and the remedy that already ships.
# ⚠️ M3 is green against the unfixed script too — it drifts, for the wrong reason. M4/M6
#    are what separate a refusal from a misparse.
contains "M3 map is DRIFT, not a pass"  "DRIFT L7" "$B"
contains "M4 the refused field is named" "install.skills" "$B"
contains "M6 the shipped remedy is named" "df-lock-migrate.py" "$B"

# M5 nor may it claim the check succeeded. This is the assertion that separates "L7 was
#    taught the map shape" from "L7 was taught to ignore the map shape".
#    ⚠️ M5 is GREEN against the unfixed script too — the map DRIFTs there, so the PASS
#    sentence is absent for the wrong reason. It proves nothing in the RED run and is kept
#    only as the guard that stops the fix from over-correcting into a blanket PASS.
absent "M5 map does not claim every declaration has a source" \
       "every declaration has a source and every source has a declaration" "$B"

echo "=== the real artefact: 50 false positives must go to 0 ==="

# The live org layer, reproduced at the shape and scale that produced the 50 lines:
# 46 skills + 4 hooks, map-spelled, no *Sources key.
mkdir -p "$WORK/real"
jq -n '
  { vendorDir:"vendor", upstreams:{},
    install: {
      "$comment":"Filled by new-org-layer.sh ...",
      skills: ( [range(46)] | map({ ("skill-" + (tostring)): ("upstream:dark-factory/skills/skill-" + tostring) }) | add ),
      hooks:  ( [range(4)]  | map({ ("hook-"  + (tostring)): ("upstream:dark-factory/hooks/hook-"   + tostring) }) | add )
    } }' > "$WORK/real/loom.lock.json"
eq "R0 fixture is 46 skills" 46 "$(jq -r '.install.skills|length' "$WORK/real/loom.lock.json")"
eq "R0 fixture is 4 hooks"    4 "$(jq -r '.install.hooks|length'  "$WORK/real/loom.lock.json")"
B="$(l7 real)"
eq "R1 zero 'declared with no' lines" 0 "$(printf '%s' "$B" | grep -c 'declared with no')"
contains "R2 both map fields are named" "install.hooks" "$B"

echo "=== a scalar is malformed under BOTH contracts ==="
# NOTE ON S2. The first draft asserted only that the word "string" appeared somewhere in
# the block. That passed against the UNFIXED script — because jq itself printed "Cannot
# iterate over string" to stderr. An assertion satisfied by a crash message is not a check,
# so it asserts the whole verdict phrase instead, which only a deliberate type test emits.
B="$(l7 scalar)"
contains "S1 a string install.hooks is DRIFT" "DRIFT L7" "$B"
contains "S2 the verdict names the field AND the bad type" "install.hooks has unexpected type 'string'" "$B"
absent   "S3 the type test runs BEFORE jq iterates" "Cannot iterate over" "$B"

echo "=== an EMPTY map is still the old shape — the guard dies on any object ==="
# This is the live case, not a hypothetical: providentiaww/dark-factory-onedroid
# templates/tier3-instance/instance.lock.json is `{}` on BOTH keys, while Tier 1's own copy
# of that template is `[]` + a *Sources map. Every Tier 3 instance minted from the OneDroid
# org layer inherits the old shape. Letting `{}` pass here would hide precisely that.
B="$(l7 empty-map)"
contains "E1 an empty map is refused, like a full one" "DRIFT L7" "$B"
contains "E2 the field is named" "install.hooks" "$B"
absent   "E3 and it does not claim agreement" \
         "every declaration has a source and every source has a declaration" "$B"

echo "=== nothing to check is a fact; agreement is a claim ==="
B="$(l7 no-install)"
absent "N1 an absent install key does not claim agreement" \
       "every declaration has a source and every source has a declaration" "$B"
# ⚠️ N2 (and M5) are green against the unfixed script too — over-correction guards, not
# evidence. They stop the fix from turning "nothing declared" into a failure.
absent "N2 an absent install key is not drift either" "DRIFT L7" "$B"

echo "=== the contract: L7 and the shipped installer classify the SAME fixture alike ==="
# ⚠️ G0 is green either way — it proves the harness can see the guard REFUSE, without which
# every "they agree" below could be satisfied by an installer that never runs.
if [ -f "$INST" ]; then
  # Both directions of the probe, so neither verdict can be the harness's own artefact.
  eq "G0 harness sees the guard REFUSE a map"    refuse "$(guard map-shape)"
  eq "G0 harness sees the guard ACCEPT an array" accept "$(guard array-good)"
  for f in array-good array-fwd array-rev map-shape empty-map scalar no-install; do
    case "$(l7 "$f")" in *"DRIFT L7 lockfile is in a shape the installers refuse"*) v=refuse ;; *) v=accept ;; esac
    eq "G:$f installer and L7 agree" "$(guard "$f")" "$v"
  done
else
  bad "G* installer template present" "not at $INST"
fi

echo ""
echo "passed $PASS  failed $FAIL"

# The assertion-count contract read by run-tests.sh (see its header). Exit status alone
# cannot tell "asserted every case below" from "asserted nothing" — both exit 0 — so the
# count is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
