#!/usr/bin/env bash
# test-instance-test-harness.sh — a MINTED instance gets a test harness, and that harness can fail.
#
# TWO CLAIMS, AND THEY FAIL IN OPPOSITE DIRECTIONS.
#
#   A. bootstrap.sh puts the runner, the suites and the CI workflow INTO the instance it
#      creates. ⛔ THIS WAS FALSE UNTIL 2026-09-08 AND A GREEN SUITE HID IT. This template has
#      shipped `boot-kit/scripts/run-tests.sh`, `boot-kit/tests/` and
#      `.github/workflows/gate.yml` since 2026-08-31, and bootstrap.sh copied none of them —
#      so every instance ever minted came out with no runner, no suites and no CI. Measured on
#      six live records: one had them, added by hand months later, and five had zero.
#      `test-instance-ci.sh` was passing the whole time, correctly, because it measures THIS
#      DIRECTORY. Nothing measured what the mint produces. Section A runs bootstrap.sh for
#      real and reads the OUTPUT, which is the only thing that could have caught it.
#
#   B. the shipped record-shape suite actually catches a broken record. A suite that has only
#      ever been seen passing has not been shown to check anything — and this one now runs in
#      every kit, so an inert copy of it would spread the false assurance rather than contain
#      it. Section B feeds it one deliberately broken lockfile per defect class and asserts it
#      goes RED, naming the defect.
#
# ⚠️ NOTHING HERE INSTALLS. No $HOME is touched, no `claude` is called, no network is needed —
# bootstrap.sh falls back to the local checkout's HEAD when the remote is unreachable, which is
# what makes this runnable on a laptop with the wifi off.
#
# Usage: bash starter-kit/instance/tests/test-instance-test-harness.sh
# Exit:  0 = both claims hold   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"
BOOTSTRAP="$KIT/bootstrap.sh"
SHAPE="$KIT/boot-kit/instance-tests/test-record-shape.sh"
[ -f "$BOOTSTRAP" ] || { echo "missing $BOOTSTRAP"; exit 2; }
[ -f "$SHAPE" ]     || { echo "missing $SHAPE";     exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "jq required";  exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s -- %s\n' "$1" "$2"; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1" "$2 is absent"; fi; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/insttest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "=== A: what bootstrap.sh actually mints ==="
MINT="$WORK/minted"
BOOT_OUT="$(bash "$BOOTSTRAP" harness-fixture "$MINT" 2>&1)" || true
exists "A1 the runner is in the instance"   "$MINT/boot-kit/scripts/run-tests.sh"
exists "A2 the suites directory is in the instance" "$MINT/boot-kit/tests"
exists "A3 record-shape ships with it"      "$MINT/boot-kit/tests/test-record-shape.sh"
# ⚠️ AND THE TEMPLATE-ONLY SUITE MUST NOT SHIP. test-boot-kit.sh asserts the session hook is
# present in boot-kit/hooks/, which is true here and FALSE in a mint — the hook is declared in
# the lockfile and installed from the vendored upstream, on purpose. Measured: shipping it made
# a correct fresh instance fail its own gate on the first run.
if [ -e "$MINT/boot-kit/tests/test-boot-kit.sh" ]; then
  bad "A3b the template-only suite does NOT ship" "test-boot-kit.sh landed in the mint — it fails there by construction"
else
  ok "A3b the template-only suite does NOT ship"
fi
exists "A4 CI is wired in the instance"     "$MINT/.github/workflows/gate.yml"
contains "A5 it says so, with a count" "test harness: run-tests.sh" "$BOOT_OUT"

# The runner is executable, or CI runs `bash <file>` and this passes by luck on one platform.
if [ -x "$MINT/boot-kit/scripts/run-tests.sh" ]; then ok "A6 the runner is executable"
else bad "A6 the runner is executable" "not +x — a copy that loses the mode bit"; fi

# ⚠️ THE CLAIM THAT MATTERS: the harness RUNS in the mint and goes green there. Present-and-
# broken is the state this whole section exists to distinguish from present-and-working, and a
# file-existence check cannot tell them apart.
#
# ⚠️ `env -u RUN_TESTS_ACTIVE` IS LOAD-BEARING AND IT IS NOT A GUARD BEING DEFEATED. The runner
# exports that variable and then REFUSES to run when the tree it is sweeping contains the
# runner file itself — the infinite-recursion guard, and a correct one. The mint's runner is a
# DIFFERENT COPY in a throwaway tree, which the guard cannot distinguish from a genuine
# re-entry because it compares self-against-root. Clearing it for this one call is provably
# safe here and only here: the mint contains exactly one suite (`test-record-shape.sh`) and it
# is not this file, so there is nothing for the recursion to recurse into.
# Measured 2026-09-08: without this, A7 fails, the instance template's own gate then fails, and
# `test-instance-ci.sh` B1 fails with it — three red suites from one inherited variable.
RUN_OUT="$( cd "$MINT" && env -u RUN_TESTS_ACTIVE bash boot-kit/scripts/run-tests.sh 2>&1 )"; RUN_RC=$?
if [ "$RUN_RC" -eq 0 ]; then ok "A7 the minted instance passes its own gate"
else bad "A7 the minted instance passes its own gate" "exit $RUN_RC: $(printf '%s' "$RUN_OUT" | tail -3 | tr '\n' ' ')"; fi
contains "A8 and it discovered the record-shape suite" "test-record-shape.sh" "$RUN_OUT"

echo ""
echo "=== B: the shipped suite is not inert ==="
# One fixture per defect class. `RECORD_ROOT` points the suite at a throwaway tree, the same
# way LOOM_LIVE points the installer at a throwaway ~/.claude: a suite that could only be
# tested against a real record is a suite nobody tests.
GOODPIN=0123456789012345678901234567890123456789
mkfix() { # mkfix <case> <lockfile-json>
  mkdir -p "$WORK/$1"
  printf '%s\n' "$2" > "$WORK/$1/loom.lock.json"
}
shape_out() { RECORD_ROOT="$WORK/$1" bash "$SHAPE" 2>&1; }
shape_rc()  { RECORD_ROOT="$WORK/$1" bash "$SHAPE" >/dev/null 2>&1; echo $?; }

mkfix control "$(jq -n --arg c "$GOODPIN" '{upstreams:{"dark-factory":{commit:$c}}, install:{skills:[],hooks:[]}}')"
if [ "$(shape_rc control)" = "0" ]; then ok "B0 control: a well-formed record passes"
else bad "B0 control: a well-formed record passes" "$(shape_out control | tail -2 | tr '\n' ' ')"; fi

mkfix nolock ""
rm -f "$WORK/nolock/loom.lock.json"
mkdir -p "$WORK/nolock"
contains "B1 a record with no lockfile is a broken record" "no *.lock.json found" "$(shape_out nolock)"

mkfix badjson '{ this is not json'
contains "B2 invalid JSON is named as such" "is not valid JSON" "$(shape_out badjson)"

mkfix branchpin "$(jq -n '{upstreams:{"dark-factory":{commit:"main"}}, install:{skills:[],hooks:[]}}')"
contains "B3 a branch where a sha belongs" "is not a 40-character sha" "$(shape_out branchpin)"

mkfix placeholder "$(jq -n '{upstreams:{"dark-factory":{commit:"__T1_COMMIT__"}}, install:{skills:[],hooks:[]}}')"
contains "B4 an unresolved placeholder pin" "still the placeholder" "$(shape_out placeholder)"

# The pre-split MAP shape: install.sh refuses it outright, so a verifier that accepted it would
# be more permissive than the installer — the asymmetry this suite exists to close.
mkfix mapshape "$(jq -n --arg c "$GOODPIN" '{upstreams:{"dark-factory":{commit:$c}}, install:{skills:{"a":"b"},hooks:[]}}')"
contains "B5 the old MAP shape is refused" "install.skills is 'object'" "$(shape_out mapshape)"

mkfix orphan "$(jq -n --arg c "$GOODPIN" '{upstreams:{"dark-factory":{commit:$c}}, install:{skills:["ghost"],skillSources:{},hooks:[]}}')"
contains "B6 a declaration with no source" "declared with no source" "$(shape_out orphan)"

mkfix unused "$(jq -n --arg c "$GOODPIN" '{upstreams:{"dark-factory":{commit:$c}}, install:{skills:[],skillSources:{"stray":"x/y"},hooks:[]}}')"
contains "B7 a source nothing declares" "nothing declares" "$(shape_out unused)"

# `$`-prefixed keys are prose for the human. A check that forgets that reports the
# documentation as a broken source — wrong on every CORRECT lockfile, which is the fastest way
# to teach somebody to skip warnings.
mkfix noteskey "$(jq -n --arg c "$GOODPIN" '{upstreams:{"dark-factory":{commit:$c}}, install:{skills:[],skillSources:{"$comment":"prose"},hooks:[]}}')"
if [ "$(shape_rc noteskey)" = "0" ]; then ok "B8 a \$-prefixed note is not mistaken for an entry"
else bad "B8 a \$-prefixed note is not mistaken for an entry" "$(shape_out noteskey | grep FAIL | head -1)"; fi

mkfix badplugin "$(jq -n --arg c "$GOODPIN" '{upstreams:{"dark-factory":{commit:$c}}, install:{skills:[],hooks:[],plugins:[{name:"p",source:"local:x",dest:"~/somewhere/p"}]}}')"
OUT="$(shape_out badplugin)"
contains "B9 a plugin source that is not upstream:" "is not upstream:<path>" "$OUT"
contains "B10 a plugin dest nothing would load" "outside ~/.claude/skills/" "$OUT"

mkfix badmkt "$(jq -n --arg c "$GOODPIN" '{upstreams:{"dark-factory":{commit:$c}}, install:{skills:[],hooks:[],marketplacePlugins:[{name:"p",marketplace:"m",scope:"project"}]}}')"
OUT="$(shape_out badmkt)"
contains "B11 a marketplace plugin at the wrong scope" "only 'user' installs a MACHINE fact" "$OUT"
contains "B12 a marketplace plugin with no source is not installable elsewhere" "has no marketplaceSource" "$OUT"

# ⚠️ THE TOKEN SHAPE IS ASSEMBLED, NEVER WRITTEN OUT. A literal `gh``p_…` here is itself a
# secret-shaped string in a file this repo PUBLISHES, and the publish gate caught it — P5,
# correctly, on the first run after this suite was written. Splitting the prefix keeps the
# fixture exact for the checker under test while leaving nothing in the committed bytes for the
# gate to find. The alternative was an exemption, and the gate's own advice is the opposite:
# weakening the check to accommodate a file is how a pattern class goes inert.
FAKE_TOKEN="gh""p_0123456789abcdefghij"
mkfix secret "$(jq -n --arg c "$GOODPIN" --arg t "$FAKE_TOKEN" '{upstreams:{"dark-factory":{commit:$c}}, install:{skills:[],hooks:[]}, "$oops":$t}')"
contains "B13 a secret-shaped string in a committed file" "contains a secret-shaped string" "$(shape_out secret)"

echo ""
printf 'instance test harness: %d ok, %d failed\n' "$PASS" "$FAIL"
# run-tests.sh treats a suite that exits 0 with no declared count as UNMEASURED, not a pass.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
