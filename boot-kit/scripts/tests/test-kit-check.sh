#!/usr/bin/env bash
# test-kit-check.sh — a kit may only name things this repo ships, and this must be provable.
#
# Enrolled by GLOB, per tests/README.md — "a suite is enrolled by existing". A named CI step
# would recreate the hand-maintained list that rotted until 2026-08-26, when one suite was
# named in the workflow and 22 others ran only if somebody typed the path.
#
# WHAT IT PROTECTS. A kit is a manifest, not a copy: `kits/<name>/kit.json` names skills that
# live in `skills/`. A kit naming a skill it does not ship is the same class `tier-check.py`
# catches one level up — a reference that resolves on the authoring machine and nowhere else,
# invisible to every other gate because a skill name is not a file path and the skill IS
# present locally.
#
# Usage: bash boot-kit/scripts/tests/test-kit-check.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
ROOT="$(cd "$SCRIPTS/../.." && pwd)"
GATE="${KIT_CHECK:-$SCRIPTS/kit-check.py}"
[ -f "$GATE" ] || { echo "missing $GATE"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly present" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kitchk.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. the canary -----------------------------------------------------------
OUT="$(python3 "$GATE" --self-test 2>&1)"; RC=$?
contains "K1 self-test reports PASS"      "SELFTEST PASS"  "$OUT"
contains "K1 the canary case ran"         "--- canary:"    "$OUT"
absent   "K1 the canary was caught"       "WAS NOT CAUGHT" "$OUT"
if [ "$RC" -eq 0 ]; then ok "K1 self-test exits 0"; else bad "K1 self-test exits 0" "got $RC"; fi

# ---- 2. this repo's own kits all resolve ------------------------------------
OUT="$(python3 "$GATE" "$ROOT" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "K2 shipped kits all resolve"; else bad "K2 shipped kits all resolve" "rc=$RC"; fi
contains "K2 and it reports how many"     "kits   :"       "$OUT"

# ---- 3. every failure mode, each separately ---------------------------------
# One fixture per mode. A single fixture breaking three ways proves only that the FIRST
# check fires — the other two could be inert and the test would still pass.
mkkit() { # mkkit <root> <kitname> <json>
  mkdir -p "$1/kits/$2"; printf '%s' "$3" > "$1/kits/$2/kit.json"
}
mkskill() { mkdir -p "$1/skills/$2"; : > "$1/skills/$2/SKILL.md"; }

for case in ghost noname empty nodesc; do
  R="$WORK/$case"; mkdir -p "$R"; mkskill "$R" alpha
done
mkkit "$WORK/ghost"  k '{"name":"k","description":"d","skills":["alpha","ghost"]}'
mkkit "$WORK/noname" k '{"name":"WRONG","description":"d","skills":["alpha"]}'
mkkit "$WORK/empty"  k '{"name":"k","description":"d","skills":[]}'
mkkit "$WORK/nodesc" k '{"name":"k","skills":["alpha"]}'

OUT="$(python3 "$GATE" "$WORK/ghost" 2>&1)"
contains "K3 a skill that is not shipped is caught"    "not shipped"  "$OUT"
OUT="$(python3 "$GATE" "$WORK/noname" 2>&1)"
contains "K3 name != directory is caught"              "!= directory" "$OUT"
OUT="$(python3 "$GATE" "$WORK/empty" 2>&1)"
contains "K3 an empty kit is caught"                   "zero skills"  "$OUT"
OUT="$(python3 "$GATE" "$WORK/nodesc" 2>&1)"
contains "K3 a missing description is caught"          "description"  "$OUT"

# ---- 4. the over-correction guards ------------------------------------------
# Two kits naming ONE skill must NOT be a finding. "One artifact, one home" governs which
# REPO owns the directory; a kit only references by name, so overlap creates no second copy
# and nothing that can drift. Flagging it would make the two rules contradict each other and
# force somebody to turn one off.
R="$WORK/overlap"; mkdir -p "$R"; mkskill "$R" alpha
mkkit "$R" one '{"name":"one","description":"d","skills":["alpha"]}'
mkkit "$R" two '{"name":"two","description":"d","skills":["alpha"]}'
OUT="$(python3 "$GATE" "$R" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "K4 two kits naming one skill is NOT a finding"; else bad "K4 overlap is not a finding" "rc=$RC"; fi

# A skill in no kit is REPORTED, never failed — it may be standalone or newly added.
R="$WORK/orphan"; mkdir -p "$R"; mkskill "$R" alpha; mkskill "$R" lonely
mkkit "$R" one '{"name":"one","description":"d","skills":["alpha"]}'
OUT="$(python3 "$GATE" "$R" 2>&1)"; RC=$?
contains "K4 an unbundled skill is reported"           "in no kit"    "$OUT"
if [ "$RC" -eq 0 ]; then ok "K4 ...but does not fail the gate"; else bad "K4 orphan must not fail" "rc=$RC"; fi

# A repo with no kits/ at all must pass — every consumer that has not adopted kits yet.
R="$WORK/nokits"; mkdir -p "$R"; mkskill "$R" alpha
OUT="$(python3 "$GATE" "$R" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "K4 a repo with no kits/ passes"; else bad "K4 no kits/ passes" "rc=$RC"; fi

echo ""
printf 'passed %d  failed %d\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
