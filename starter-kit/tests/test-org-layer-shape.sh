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
T3T="$T2T/templates/tier3-instance"
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
GT3="$GT3DIR/install.sh"
eq "E9 the minted layer carries a tier-3 template" "yes" "$([ -f "$GT3" ] && echo yes || echo no)"
# THE ONLY DIFFERENCE IS THE PLACEHOLDERS. This is the byte-for-byte pin between the
# generator's template and its output — the one pair CI can see. It does NOT pin a layer
# that was minted months ago and edited since: that copy lives in another repo, and the
# only thing that ever detects ITS drift is someone diffing it by hand. Which is how a
# better warning string sat unshared in a minted copy while the template kept the worse
# one.
#
# ⚠️ AND THIS PIN USED TO NAME A FILE RATHER THAN THE ARTIFACT. It covered install.sh and
# nothing else, while the template ships seven files. Measured 2026-09-01 against the one
# layer minted from it: install.sh was the ONE file whose only difference was the
# placeholder, and the other three that differ each held a real divergence — a README
# paragraph the fork had and the template did not, an instance.lock.json the template had
# documented further, a CLAUDE.md that happened to be clean. A pin over one file of seven
# reported green through all of it. The fix is not a better file to name: it is to stop
# naming one.
E10_DRIFT=0; E10_N=0
while IFS= read -r rel; do
  E10_N=$((E10_N + 1))
  d="$(diff <(sed -e "s|__ORG_LAYER_NAME__|scratchlayer|g" \
                  -e "s|__ORG_REPO__|acme/scratchlayer|g" \
                  -e "s|__ORG_DISPLAY__|Scratch|g" "$T3T/$rel") \
            "$GT3DIR/$rel" 2>&1)"
  if [ -n "$d" ]; then
    E10_DRIFT=$((E10_DRIFT + 1))
    echo "     drift in $rel"
  fi
done < <(cd "$T3T" && find . -type f | sed -e "s:^\./::" | sort)
eq "E10 every minted tier-3 file is the template with only the org placeholders resolved" "0" "$E10_DRIFT"
# The oracle needs its own control. A find that matches nothing leaves E10 comparing zero
# files and reporting 0 drift — green, and meaningless. This suite has already been bitten
# by a count that stopped counting.
eq "E10a the pin actually compared the whole template" "7" "$E10_N"
absent "E11 no org template token survives into the minted installer" "__ORG_DISPLAY__" "$(slurp "$GT3")"
# A .bak is not a file the generator meant to ship. It substitutes with `sed -i.bak` and
# removes the backup on success — so one surviving anywhere means a substitution failed
# quietly, and the minted layer carries a pre-substitution copy of a file it also carries
# resolved. The Codex importer shipped six of these as if they were hooks.
eq "E12 no .bak survives anywhere in the minted layer" "0" \
   "$(find "$E/dest/scratchlayer" -name '*.bak' -type f | wc -l | tr -d ' ')"

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

echo "=== H. tier-3 instance: additions use the one shape, decoy planted ==="
H="$WORK/h"; mkdir -p "$H/vendor/orglayer" "$H/skills/my-skill" "$H/hooks" \
                      "$H/vendor/skills/my-skill" "$H/vendor/hooks"
echo 'MY OWN SKILL' > "$H/skills/my-skill/SKILL.md"
printf 'MY OWN HOOK home=__HOME__\n' > "$H/hooks/my-hook.sh"
echo 'DECOY SKILL FROM VENDOR' > "$H/vendor/skills/my-skill/SKILL.md"
printf 'DECOY HOOK FROM VENDOR\n' > "$H/vendor/hooks/my-hook.sh"
# A minimal but REAL vendored Tier 2, so the delegation step is the real installer.
mk_org "$H/vendor/orglayer" '{"skills":[],"skillSources":{},"hooks":[],"hookSources":{}}'
( cd "$H/vendor/orglayer" && git init -q . && git add -A >/dev/null 2>&1 ) || true
cp "$T3T/install.sh" "$H/install.sh"
jq -n '{instance:"scratch", agentName:"x", upstreams:{orglayer:{repo:"acme/orglayer", ref:"deadbeef"}},
        vendorDir:"vendor",
        install:{skills:["my-skill"], skillSources:{"my-skill":"local:skills/my-skill"},
                 hooks:["my-hook.sh"], hookSources:{"my-hook.sh":"local:hooks/my-hook.sh"}},
        notRestorable:{"gh auth login":"credentials cannot live in a lockfile"}}' > "$H/instance.lock.json"
OUT="$( cd "$H" && CLAUDE_HOME="$H/live" bash install.sh --offline 2>&1 )"
eq       "H1 a local: instance skill is the instance copy, not the decoy" "MY OWN SKILL" "$(slurp "$H/live/skills/my-skill/SKILL.md")"
contains "H2 a local: instance hook is the instance copy" "MY OWN HOOK" "$(slurp "$H/live/hooks/my-hook.sh")"
absent   "H3 the instance hook decoy was not installed"   "DECOY HOOK"  "$(slurp "$H/live/hooks/my-hook.sh")"
contains "H4 __HOME__ is rehydrated"                      "home=$HOME"  "$(slurp "$H/live/hooks/my-hook.sh")"

echo "=== I. tier-3 instance: the old map shape is refused there too ==="
I="$WORK/i"; cp -R "$H" "$I"; rm -rf "$I/live"
jq '.install = {skills:{"my-skill":"skills/my-skill"}, hooks:{}}' "$H/instance.lock.json" > "$I/instance.lock.json"
OUT="$( cd "$I" && CLAUDE_HOME="$I/live" bash install.sh --offline 2>&1 )"
contains "I1 the old shape is refused at tier 3"     "df-lock-migrate" "$OUT"
eq       "I2 nothing was installed from the old shape" ""              "$(ls "$I/live/skills" 2>/dev/null)"

echo "=== J. the duplicated reader has not drifted between the two tier templates ==="
# The block is duplicated on purpose — each tier template must stand alone in a fresh
# clone with nothing vendored. Duplication that nothing checks is just deferred drift, so
# the two copies are compared byte for byte rather than trusted to stay in step.
extract() { sed -n '/^# --- BEGIN shared install-source reader/,/^# --- END shared install-source reader/p' "$1"; }
R2="$(extract "$T2T/install.sh")"; R3="$(extract "$T3T/install.sh")"
if [ -z "$R2" ]; then FAIL=$((FAIL+1)); echo "  FAIL J1 -- no reader block in the tier-2 installer"
elif [ "$R2" = "$R3" ]; then PASS=$((PASS+1)); echo "  ok   J1 the tier-2 and tier-3 reader blocks are byte-identical"
else FAIL=$((FAIL+1)); echo "  FAIL J1 the reader blocks have drifted:"; diff <(printf '%s' "$R2") <(printf '%s' "$R3") | sed 's/^/       /'; fi
eq "J2 the block is not empty in tier 3" "0" "$([ -n "$R3" ] && echo 0 || echo 1)"

echo ""
echo "$PASS passed, $FAIL failed"

# The assertion-count contract read by run-tests.sh. Exit status alone cannot tell
# "asserted every one of these" from "asserted nothing" — both exit 0 — so the count
# is DECLARED here rather than parsed out of the summary line above it.
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
