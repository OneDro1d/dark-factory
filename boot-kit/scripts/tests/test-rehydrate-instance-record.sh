#!/usr/bin/env bash
# test-rehydrate-instance-record.sh — rehydrate installs the record it is HANDED, not the root file.
#
# Enrolled by GLOB, per tests/README.md — "a suite is enrolled by existing".
#
# ⛔ WHAT IT PROTECTS. A kit holds one record per machine: the root loom.lock.json plus
# instances/<machine>/loom.lock.json. Until 2026-09-11 rehydrate.sh read the literal
# "loom.lock.json" and nothing else, so an install that named a machine's record had that record
# VERIFIED and the ROOT record's skills and hooks INSTALLED — two records in one install, each
# step reporting success about its own. The fixture gives the root and the machine record
# DIFFERENT skills, so the two cannot be mistaken for each other.
#
# Usage: bash boot-kit/scripts/tests/test-rehydrate-instance-record.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
REHYDRATE="$SCRIPTS/rehydrate.sh"
[ -f "$REHYDRATE" ] || { echo "missing $REHYDRATE"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/rh-record.XXXXXX")"
trap 'rm -rf "$W"' EXIT

mkdir -p "$W/inst/vendor/dark-factory/skills/root-skill" "$W/inst/vendor/dark-factory/skills/machine-skill"
printf 'x\n' > "$W/inst/vendor/dark-factory/skills/root-skill/SKILL.md"
printf 'x\n' > "$W/inst/vendor/dark-factory/skills/machine-skill/SKILL.md"
record() {  # record <path> <skill>
  mkdir -p "$(dirname "$1")"
  jq -n --arg s "$2" '{instance:"t", vendorDir:"vendor", upstreams:{},
    install:{skills:[$s], skillSources:{($s):("dark-factory/skills/"+$s)}, hooks:[], hookSources:{}}}' > "$1"
}
record "$W/inst/loom.lock.json" root-skill
record "$W/inst/instances/m/loom.lock.json" machine-skill
ln -s ../../vendor "$W/inst/instances/m/vendor"

# rehydrate takes its kit root from the CURRENT DIRECTORY, so every case runs from the kit root.
rh() {  # rh <live-dir> [env assignments...] -- [args...]
  local live="$1"; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  # LOOM_BIN pinned too: rehydrate links df-mission into ${LOOM_BIN:-~/.local/bin}, and a suite run
  # outside run-tests.sh (which pins both) must not reach the real one.
  ( cd "$W/inst" && env -u LOOM_LOCK LOOM_LIVE="$live" LOOM_BIN="$live-bin" "${envs[@]+"${envs[@]}"}" bash "$REHYDRATE" --offline "$@" 2>&1 )
}
linked() { [ -L "$1/skills/$2" ]; }

echo "=== R1: LOOM_LOCK names the machine's record -> THAT record's skills are installed ==="
rh "$W/l1" LOOM_LOCK=instances/m/loom.lock.json -- >/dev/null
linked "$W/l1" machine-skill && ok "R1 the machine record's skill is linked" || bad "R1 the machine record's skill is linked" "absent"
linked "$W/l1" root-skill && bad "R1 the root record's skill is NOT linked" "the root record was installed instead" || ok "R1 the root record's skill is NOT linked"

echo "=== R2: --lock=<machine record> does the same ==="
rh "$W/l2" -- --lock=instances/m/loom.lock.json >/dev/null
linked "$W/l2" machine-skill && ok "R2 --lock= installs the machine record" || bad "R2 --lock= installs the machine record" "absent"
linked "$W/l2" root-skill && bad "R2 --lock= does not install the root record" "root-skill linked" || ok "R2 --lock= does not install the root record"

echo "=== R3: no flag, no env -> the root record, as before (control) ==="
rh "$W/l3" -- >/dev/null
linked "$W/l3" root-skill && ok "R3 the root record is the default" || bad "R3 the root record is the default" "absent"
linked "$W/l3" machine-skill && bad "R3 the machine record is not installed by default" "machine-skill linked" || ok "R3 the machine record is not installed by default"

echo "=== R4: the flag wins over the environment ==="
rh "$W/l4" LOOM_LOCK=loom.lock.json -- --lock=instances/m/loom.lock.json >/dev/null
linked "$W/l4" machine-skill && ok "R4 --lock= overrides LOOM_LOCK" || bad "R4 --lock= overrides LOOM_LOCK" "the env record won"

echo "=== R5: '--lock <space> path' and unknown flags are refused, not ignored ==="
OUT5="$(rh "$W/l5" -- --lock instances/m/loom.lock.json)"; RC5=$?
[ "$RC5" -eq 2 ] && ok "R5 '--lock <space>' exits 2" || bad "R5 '--lock <space>' exits 2" "rc=$RC5"
case "$OUT5" in *"takes an = sign"*) ok "R5 and says --lock takes an = sign" ;; *) bad "R5 and says --lock takes an = sign" "$OUT5" ;; esac
[ ! -e "$W/l5/skills" ] && ok "R5 nothing was installed" || bad "R5 nothing was installed" "$(ls "$W/l5/skills" 2>&1)"
rh "$W/l6" -- --bogus >/dev/null; RC6=$?
[ "$RC6" -eq 2 ] && ok "R6 an unknown flag exits 2" || bad "R6 an unknown flag exits 2" "rc=$RC6"

echo
printf 'rehydrate instance record: %d ok, %d failed\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
