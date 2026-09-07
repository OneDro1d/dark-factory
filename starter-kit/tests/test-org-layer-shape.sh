#!/usr/bin/env bash
# test-org-layer-shape.sh — the org layer reads `install` the same way the engine does.
#
# WHY THIS EXISTS. `install.skills` had four readings live at once. The engine's was
# chosen (an ARRAY of names plus a `*Sources` map, with `local:` / `upstream:` / bare
# source values); the org-layer templates were left on their own. This suite is the
# other half: it pins the generator and both template installers to the one shape, and
# it pins the two things that shape makes possible and a single map could not express.
#
# Three claims are load-bearing and are asserted directly, never reasoned about:
#
#   1. `local:` resolves against the LOCKFILE's directory, never against vendorDir. Every
#      `local:` case here plants a DECOY at the identical relative path inside vendor/, so
#      a wrong resolution still SUCCEEDS and only file CONTENT can tell the two apart.
#      Exit status cannot, and neither can a path assertion that checks only the path it
#      hoped for.
#   2. A name with no source, and a source with no name, both install nothing while still
#      reading like a declaration. Each must be reported, in both directions.
#   3. The OLD map shape is REFUSED, not silently accepted. An installer that reads both
#      shapes forever is how a third reading appears; a refusal that names the converter
#      is a positive negative and is fixed in one line.
#
# Usage: bash starter-kit/tests/test-org-layer-shape.sh
# Exit:  0 = every case behaves   1 = at least one does not
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T1="$(cd "$SELF/../.." && pwd)"                       # the Tier 1 checkout
KIT="$T1/starter-kit"
T2T="$KIT/templates/tier2-org"
# REPOINTED 2026-09-07. This was $T2T/templates/tier3-instance - the org layer's OWN
# copy of the instance kit, deleted when Tier 1's starter-kit/instance/ became the single
# Tier-3 generator (operator decision: "T1"). The fixture is "the tier-3 installer this
# repo ships"; only which file that is has moved.
T3T="$KIT/instance"
GEN="$KIT/new-org-layer.sh"
MIGRATE="$T1/boot-kit/scripts/df-lock-migrate.py"
LOCKVERIFY="$T1/boot-kit/scripts/lock-verify.sh"
for f in "$T2T/install.sh" "$T2T/org.lock.json" "$T3T/install.sh" "$GEN"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/orgshape.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

contains() { case "$3" in *"$2"*) PASS=$((PASS+1)); echo "  ok   $1" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL $1 -- '$2' not in output" ;; esac; }
absent()  { case "$3" in *"$2"*) FAIL=$((FAIL+1)); echo "  FAIL $1 -- '$2' unexpectedly in output" ;;
  *) PASS=$((PASS+1)); echo "  ok   $1" ;; esac; }
eq()      { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1";
  else FAIL=$((FAIL+1)); echo "  FAIL $1 -- expected '$2', got '$3'"; fi; }
# Read a file that may not exist without turning a missing file into a shell error --
# the assertion should report the CONTENT mismatch, which names the decoy.
slurp() { cat "$1" 2>/dev/null || printf '<<no such file: %s>>' "$1"; }

# ---------------------------------------------------------------------------
# A scratch Tier-2 org layer, wired for the decoy test.
#
#   local:skills/org-owned   ->  <root>/skills/org-owned          OWNED BY THE ORG
#     decoy at               ->  <root>/vendor/skills/org-owned   DECOY SKILL FROM VENDOR
#
# If `local:` is ever resolved under vendorDir the install still succeeds and links the
# decoy. That is why every assertion below reads the file.
# ---------------------------------------------------------------------------
mk_org() { # mk_org <dir> <install-json>
  local d="$1" ins="$2"
  mkdir -p "$d/vendor/dark-factory/skills/from-upstream" "$d/vendor/dark-factory/hooks" \
           "$d/skills/org-owned" "$d/hooks" \
           "$d/vendor/skills/org-owned" "$d/vendor/hooks"
  echo 'UPSTREAM SKILL'       > "$d/vendor/dark-factory/skills/from-upstream/SKILL.md"
  printf 'UPSTREAM HOOK home=__HOME__\n' > "$d/vendor/dark-factory/hooks/shared.sh"
  echo 'OWNED BY THE ORG'     > "$d/skills/org-owned/SKILL.md"
  printf 'ORG HOOK home=__HOME__\n'      > "$d/hooks/org-hook.sh"
  echo 'DECOY SKILL FROM VENDOR' > "$d/vendor/skills/org-owned/SKILL.md"
  printf 'DECOY HOOK FROM VENDOR\n'      > "$d/vendor/hooks/org-hook.sh"
  cp "$T2T/install.sh" "$d/install.sh"
  jq -n --argjson ins "$ins" '{
    orgLayer:"scratch", orgDisplay:"Scratch", repo:"scratch/layer",
    upstreams:{}, vendorDir:"vendor", install:$ins,
    notRestorable:{"gh auth login":"credentials cannot live in a lockfile"}
  }' > "$d/org.lock.json"
}
run_org() { ( cd "$1" && CLAUDE_HOME="$1/live" bash install.sh --offline --no-verify 2>&1 ); }

echo "=== A. tier-2 installer: all three source forms, proven by CONTENT ==="
A="$WORK/a"; mk_org "$A" '{
  "skills":["from-upstream","org-owned"],
  "skillSources":{
    "$comment":"documentation, not an entry",
    "from-upstream":"dark-factory/skills/from-upstream",
    "org-owned":"local:skills/org-owned"
  },
  "hooks":["shared.sh","org-hook.sh"],
  "hookSources":{
    "shared.sh":"upstream:dark-factory/hooks/shared.sh",
    "org-hook.sh":"local:hooks/org-hook.sh"
  }
}'
OUT="$(run_org "$A")"
eq       "A1 bare source resolves under vendorDir"     "UPSTREAM SKILL"       "$(slurp "$A/live/skills/from-upstream/SKILL.md")"
eq       "A2 local: skill is the INSTANCE copy, not the decoy" "OWNED BY THE ORG" "$(slurp "$A/live/skills/org-owned/SKILL.md")"
contains "A3 upstream: hook resolves under vendorDir"  "UPSTREAM HOOK"        "$(slurp "$A/live/hooks/shared.sh")"
contains "A4 local: hook is the INSTANCE copy"         "ORG HOOK"             "$(slurp "$A/live/hooks/org-hook.sh")"
absent   "A5 the hook decoy was not installed"         "DECOY HOOK"           "$(slurp "$A/live/hooks/org-hook.sh")"
contains "A6 __HOME__ is rehydrated in a local: hook"  "home=$HOME"           "$(slurp "$A/live/hooks/org-hook.sh")"
absent   "A7 no unrecognised-source warning"           "unrecognised source"  "$OUT"
contains "A8 a \$comment key in *Sources is not counted as missing" "2 skills linked, 0 missing" "$OUT"
absent   "A9 a \$comment key is never reported as an entry"              "\$comment" "$OUT"

echo "=== B. tier-2 installer: both directions of the array/map disagreement ==="
B="$WORK/b"; mk_org "$B" '{
  "skills":["from-upstream","declared-but-sourceless"],
  "skillSources":{"from-upstream":"dark-factory/skills/from-upstream","sourced-but-undeclared":"local:skills/org-owned"},
  "hooks":[], "hookSources":{}
}'
OUT="$(run_org "$B")"
contains "B1 a declared name with no source is named"   "declared-but-sourceless" "$OUT"
contains "B2 a source with no declaration is named"     "sourced-but-undeclared"  "$OUT"
absent   "B3 the undeclared source was NOT installed"   "org-owned"               "$(ls "$B/live/skills" 2>/dev/null)"

echo "=== C. tier-2 installer: a source that climbs out is refused, not normalised ==="
C="$WORK/c"; mk_org "$C" '{
  "skills":["escapee"], "skillSources":{"escapee":"local:../elsewhere/escapee"},
  "hooks":[], "hookSources":{}
}'
mkdir -p "$WORK/elsewhere/escapee"; echo 'OUTSIDE THE TREE' > "$WORK/elsewhere/escapee/SKILL.md"
OUT="$(run_org "$C")"
contains "C1 the escaping source is refused"            "refus"                   "$OUT"
eq       "C2 nothing outside the tree was installed"    ""                        "$(ls "$C/live/skills" 2>/dev/null)"

echo "=== D. tier-2 installer: the OLD map shape is refused and names the converter ==="
D="$WORK/d"; mk_org "$D" '{"skills":{"org-owned":"local:skills/org-owned"},"hooks":{}}'
OUT="$(run_org "$D")"; RC_D=$?
contains "D1 the old map shape is named as a MAP, not read" "is a MAP" "$OUT"
contains "D2 the refusal names the converter"           "df-lock-migrate"         "$OUT"
eq       "D3 nothing was installed from the old shape"  ""                        "$(ls "$D/live/skills" 2>/dev/null)"

echo "=== E. the generator writes the one shape ==="
E="$WORK/e"; mkdir -p "$E/t1/skills/alpha" "$E/t1/skills/beta" "$E/t1/hooks" "$E/bin" "$E/dest"
touch "$E/t1/skills/alpha/SKILL.md" "$E/t1/skills/beta/SKILL.md" "$E/t1/hooks/one.sh"
cp -R "$KIT" "$E/t1/starter-kit"
# Stub ONLY `git ls-remote`, so the generator's unresolved-pin path is exercised offline
# and every other git call still reaches the real binary.
REALGIT="$(command -v git)"
cat > "$E/bin/git" <<GITSTUB
#!/usr/bin/env bash
[ "\${1:-}" = "ls-remote" ] && exit 1
exec "$REALGIT" "\$@"
GITSTUB
chmod +x "$E/bin/git"
OUT="$(PATH="$E/bin:$PATH" bash "$E/t1/starter-kit/new-org-layer.sh" scratchlayer acme/scratchlayer "$E/dest" "Scratch" 2>&1)"
GL="$E/dest/scratchlayer/org.lock.json"
eq "E1 install.skills is an array"        "array"  "$(jq -r '.install.skills|type' "$GL" 2>/dev/null)"
eq "E2 install.skillSources is an object" "object" "$(jq -r '.install.skillSources|type' "$GL" 2>/dev/null)"
eq "E3 install.hooks is an array"         "array"  "$(jq -r '.install.hooks|type' "$GL" 2>/dev/null)"
eq "E4 install.hookSources is an object"  "object" "$(jq -r '.install.hookSources|type' "$GL" 2>/dev/null)"
eq "E5 every generated skill name has a source" "0" \
   "$(jq -r '.install as $i | [$i.skills[] | select($i.skillSources[.] == null)] | length' "$GL" 2>/dev/null || echo ERR)"
eq "E6 every generated source has a name" "0" \
   "$(jq -r '.install as $i | [$i.skillSources | keys[] | select(startswith("$")|not) | select(([$i.skills[]] | index(.)) == null)] | length' "$GL" 2>/dev/null || echo ERR)"
eq "E7 the two Tier-1 skills are declared" "2" "$(jq -r '.install.skills|length' "$GL" 2>/dev/null)"
eq "E8 sources carry the upstream: prefix"  "true" \
   "$(jq -r '[.install.skillSources|to_entries[]|select(.key|startswith("$")|not)|.value|startswith("upstream:")]|all' "$GL" 2>/dev/null)"

# A minted org layer must be able to mint an INSTANCE. Nothing asserted that before, and
# the way it breaks is quiet: `cp -R "$TEMPLATE"/* dst` instead of `cp -R "$TEMPLATE" dst`
# drops nested directories, and every layer minted afterwards would look complete while
# being unable to produce a single machine. Same class as A3 one tier up.
GT3DIR="$E/dest/scratchlayer/templates/tier3-instance"
GT3="$E/dest/scratchlayer/scripts/new-instance.sh"
# ⚠️ E9 IS INVERTED FROM WHAT IT WAS, 2026-09-07, and the inversion is the change itself.
# It used to require the minted layer to CARRY a tier-3 template. Operator decision: Tier 1's
# starter-kit/instance/ is the single Tier-3 generator, so a layer must carry NO copy and
# stamp from the vendored Tier 1 instead. A template copied into every layer at mint time and
# never compared again is a drift surface by construction — the suite that policed it found
# four of seven files differing, in BOTH directions, on the first layer it ever ran against.
eq "E9 the minted layer carries NO tier-3 template" "no" "$([ -d "$GT3DIR" ] && echo yes || echo no)"
# ⚠️ AND THE OTHER HALF, IN THE SAME BREATH. E9 alone now asserts an ABSENCE, which a layer
# minted with no minting machinery at all would also satisfy. Deleting the template without
# repointing the script produces exactly that: a layer that looks correct and can mint
# nothing. Half a migration passes every check aimed at the half that moved.
eq "E9a and its new-instance.sh stamps from Tier 1" "yes" \
   "$(grep -q 'starter-kit/instance/bootstrap.sh' "$GT3" 2>/dev/null && echo yes || echo no)"
# ⚠️ E10 AND E10a ARE GONE, 2026-09-07, AND THE REASON THEY EXISTED IS WHY.
# They were a byte-for-byte pin between the org-layer template's tier-3 copy and its minted
# output — the only pair CI could see. Their own header recorded the limit that killed them:
# the pin "does NOT pin a layer that was minted months ago and edited since: that copy lives
# in another repo, and the only thing that ever detects ITS drift is someone diffing it by
# hand. Which is how a better warning string sat unshared in a minted copy while the template
# kept the worse one."
#
# A pin that can only see freshly minted output was always going to lose to the copies in the
# wild. Deleting the copy removes what they were guarding: there is now one Tier-3 generator,
# in Tier 1, fetched at a pinned commit, and a layer holds no second version to drift.
#
# ⚠️ WHAT WAS LOST WITH THEM, STATED RATHER THAN QUIETLY DROPPED: nothing now compares a
# minted layer's instance-generating machinery byte-for-byte, because there is no longer a
# copy to compare — E9/E9a assert the absence and the delegation instead. If a layer ever
# reintroduces a local template, E9 is what fires.
absent "E11 no org template token survives into the minted installer" "__ORG_DISPLAY__" "$(slurp "$GT3")"
# A .bak is not a file the generator meant to ship. It substitutes with `sed -i.bak` and
# removes the backup on success — so one surviving anywhere means a substitution failed
# quietly, and the minted layer carries a pre-substitution copy of a file it also carries
# resolved. The Codex importer shipped six of these as if they were hooks.
eq "E12 no .bak survives anywhere in the minted layer" "0" \
   "$(find "$E/dest/scratchlayer" -name '*.bak' -type f | wc -l | tr -d ' ')"
# A minted layer must arrive with its own gates, not just its own content. The layer is the
# only place that can check ITS tier-3 template against Tier 1 — Tier 1's CI sees one
# freshly minted pair and nothing else — so a layer minted without the suite is a layer
# whose drift is again detectable only by hand. Byte-identical because these files carry no
# org placeholder: if one ever does, this assertion is where you find out.
E13_MISSING=0
# ⚠️ test-tier3-template-pin.sh was the second entry here until 2026-09-07. It was deleted
# with the template it policed — a suite whose whole subject no longer exists is not a suite
# to keep passing. Its absence is asserted nowhere because nothing should ever look for it
# again; if a layer ships one, test-repo-shape.sh's A7 is what fires.
for suite in test-repo-shape.sh; do
  m="$E/dest/scratchlayer/scripts/tests/$suite"
  if [ ! -f "$m" ] || ! diff -q "$T2T/scripts/tests/$suite" "$m" >/dev/null 2>&1; then
    E13_MISSING=$((E13_MISSING + 1))
    echo "     missing or drifted: scripts/tests/$suite"
  fi
done
eq "E13 the minted layer ships both gate suites, byte-identical" "0" "$E13_MISSING"

echo "=== F. the generator's output survives lock-verify L7 ==="
if [ -f "$LOCKVERIFY" ] && [ -f "$GL" ]; then
  LV="$(bash "$LOCKVERIFY" --lock "$GL" 2>&1)"
  contains "F1 L7 passes on the generated lockfile"        "PASS  L7" "$LV"
  absent   "F2 L7 does not drift on the generated lockfile" "DRIFT L7" "$LV"
else
  FAIL=$((FAIL+2)); echo "  FAIL F1/F2 -- lock-verify or generated lockfile missing"
fi

echo "=== G. the converter turns the old shape into the new one ==="
G="$WORK/g"; mkdir -p "$G"
cat > "$G/org.lock.json" <<'OLD'
{
  "vendorDir": "vendor",
  "install": {
    "$comment": "keep me",
    "skills": { "alpha": "upstream:dark-factory/skills/alpha", "mine": "local:skills/mine" },
    "hooks":  { "one.sh": "upstream:dark-factory/hooks/one.sh" }
  }
}
OLD
if [ -f "$MIGRATE" ]; then
  OUT="$(python3 "$MIGRATE" --lock "$G/org.lock.json" 2>&1)"
  eq "G1 without --apply nothing is written" "object" "$(jq -r '.install.skills|type' "$G/org.lock.json")"
  contains "G2 the dry run says what it would do" "skills" "$OUT"
  OUT="$(python3 "$MIGRATE" --lock "$G/org.lock.json" --apply 2>&1)"
  eq "G3 skills became an array"        "array"  "$(jq -r '.install.skills|type' "$G/org.lock.json")"
  eq "G4 skillSources became a map"     "object" "$(jq -r '.install.skillSources|type' "$G/org.lock.json")"
  eq "G5 the source values are carried across verbatim" "local:skills/mine" \
     "$(jq -r '.install.skillSources.mine' "$G/org.lock.json")"
  eq "G6 hooks migrated too"            "array"  "$(jq -r '.install.hooks|type' "$G/org.lock.json")"
  eq "G7 the \$comment survived"        "keep me" "$(jq -r '.install."$comment"' "$G/org.lock.json")"
  OUT2="$(python3 "$MIGRATE" --lock "$G/org.lock.json" --apply 2>&1)"
  contains "G8 re-running is a no-op, and says so" "already" "$OUT2"
  eq "G9 the second run did not double anything" "2" "$(jq -r '.install.skills|length' "$G/org.lock.json")"
else
  FAIL=$((FAIL+9)); echo "  FAIL G1..G9 -- $MIGRATE does not exist"
fi

# ⚠️ SECTIONS H AND I WERE HERE AND ARE DELETED, 2026-09-07 — MOVED, NOT DROPPED.
# They drove the TIER-3 installer: H that a `local:` instance skill/hook beats a vendored
# decoy and that __HOME__ is rehydrated; I that the old map lockfile shape is refused there
# too. Both built their fixture around the org layer's own copy of the instance installer,
# which is deleted — Tier 1's starter-kit/instance/ is now the single Tier-3 generator.
#
# ⚠️ THE COVERAGE DID NOT GO ANYWHERE: starter-kit/instance/tests/test-instance-org-delegate.sh
# already asserts the same properties against the CORRECT installer, and asserts more of them —
# `local:` sources (its cases around skillSources/hookSources), `__HOME__` rehydration, the
# override reported BY NAME (F1/G1), and the re-run property that only REAL overrides are
# re-reported (H1/H2). The old-shape refusal is pinned by the lock_shape_guard now ported into
# that installer and by boot-kit/scripts/tests/test-lock-verify-l7-shape.sh, whose whole
# subject is that the installer and lock-verify L7 classify the same lockfile alike.
#
# Rebuilding H and I here would have meant re-creating a fixture for a contract another suite
# already pins, against an installer this suite is not about. This file is about the ORG LAYER;
# the tier-3 half moved out of it when the tier-3 generator did. Recorded rather than silently
# removed, because a deleted test and a moved test look identical in a diff.

echo "=== J. the reader block is duplicated NOWHERE — tier 3 delegates instead ==="
# ⚠️ J1/J2 ARE REWRITTEN, 2026-09-07, AND THE OLD PAIR IS THE BEST ARGUMENT FOR THE CHANGE.
# They used to require this block to be byte-identical in BOTH tier templates, because "each
# tier template must stand alone in a fresh clone with nothing vendored" — a real constraint,
# answered by copying, with a test to police the copy. That is the same bargain the tier-3
# template itself made, and it is the bargain the operator has now ended: Tier 1's
# starter-kit/instance/ is the only Tier-3 generator, and it reads its install sources through
# boot-kit/scripts/rehydrate.sh rather than carrying its own copy of the reader.
#
# So the assertion inverts. Tier 2 must still carry the block — a layer genuinely does stand
# alone, it is cloned and run before anything is vendored. Tier 3 must NOT, because a copy
# there is a second implementation of the one thing this refactor removed.
extract() { sed -n '/^# --- BEGIN shared install-source reader/,/^# --- END shared install-source reader/p' "$1"; }
R2="$(extract "$T2T/install.sh")"; R3="$(extract "$T3T/install.sh")"
if [ -n "$R2" ]; then PASS=$((PASS+1)); echo "  ok   J1 the tier-2 installer still carries its own reader block"
else FAIL=$((FAIL+1)); echo "  FAIL J1 -- no reader block in the tier-2 installer; a layer must stand alone in a fresh clone"; fi
# ⚠️ ASSERTING AN ABSENCE NEEDS A CONTROL, or a typo in the sed range passes it forever. J2a
# proves the extractor can still FIND a block when one is there, using the tier-2 copy J1
# just matched — without it, J2 is green on any broken extractor.
eq "J2 the tier-3 installer does NOT duplicate it" "0" "$([ -z "$R3" ] && echo 0 || echo 1)"
eq "J2a control: the extractor can find a block that exists" "0" "$([ -n "$R2" ] && echo 0 || echo 1)"

echo ""
echo "$PASS passed, $FAIL failed"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
