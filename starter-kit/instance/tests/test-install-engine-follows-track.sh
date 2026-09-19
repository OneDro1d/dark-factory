#!/usr/bin/env bash
# test-install-engine-follows-track.sh — the ENGINE a kit installs is the commit `track` resolves
# to, on the FIRST install after the ref moves.
#
# ⛔ WHAT IT PROTECTS. install.sh copies the engine (boot-kit/scripts/) in step 2 and hands the
# rest to rehydrate.sh in step 3, which resolves `track` and moves the vendored tree. With only
# rehydrate.sh resolving, step 2 copied the engine from the RECORDED commit, so the first install
# after a move ran the previous engine: a new rehydrate section appeared only on the second
# install. Skills and hooks were current (they come from the moved tree); the engine was not.
#
# The fixture Tier 1 has two commits whose STUB rehydrate.sh prints which engine it is. The record
# names A; the `stable` tag names B. Cases:
#   T1  track moved      -> the engine that RUNS is B, the copied engine is B, the stamp says B
#   T2  --frozen         -> A (control: reproducing a machine ignores track)
#   T3  no track         -> A (control: today's behaviour is unchanged)
#   T4  a track that resolves to nothing -> A, and it says so
#   T5  --dry-run        -> says it would resolve, and copies nothing
#
# RED BASELINE, measured against the pre-change install.sh via INSTALL_SRC=<old copy>: 4 of 11
# fail -- T1's three (the engine that runs, the copy and the stamp are all A) and T5's new "would
# resolve" line. T2-T4 and T5's "copied nothing" pass on both: they are controls, named so nobody
# reads 7/11 green on the old installer as coverage of the change.
#
# Usage: bash starter-kit/instance/tests/test-install-engine-follows-track.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"
INSTALL_SRC="${INSTALL_SRC:-$KIT/install.sh}"
[ -f "$INSTALL_SRC" ] || { echo "missing $INSTALL_SRC"; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "jq required";  exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/enginetrack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
GITC=(-c user.email=test@example.com -c user.name=test)

engine() {  # engine <t1 dir> <label> -- write a stub engine that announces its label
  mkdir -p "$1/boot-kit/scripts" "$1/starter-kit/instance/boot-kit/scripts"
  printf '#!/usr/bin/env bash\necho "ENGINE=%s"\n' "$2" > "$1/boot-kit/scripts/rehydrate.sh"
  printf '#!/usr/bin/env bash\necho "=== RESULT: LOCKED (fixture stub) ==="\n' > "$1/boot-kit/scripts/lock-verify.sh"
  printf '%s\n' "$2" > "$1/boot-kit/scripts/ENGINE_LABEL"
  printf '#!/bin/sh\n# INSTANCE RUNNER\n' > "$1/starter-kit/instance/boot-kit/scripts/run-tests.sh"
  chmod +x "$1/boot-kit/scripts"/*.sh
}

mk() {  # mk <case> <track or ""> -- Tier 1 with commits A, B (tag stable -> B); record pins A
  local d="$WORK/$1"
  mkdir -p "$d/t1" "$d/inst/vendor"
  engine "$d/t1" A
  git -C "$d/t1" init -q
  git "${GITC[@]}" -C "$d/t1" add -A
  git "${GITC[@]}" -C "$d/t1" commit -q -m A
  A="$(git -C "$d/t1" rev-parse HEAD)"
  engine "$d/t1" B
  git "${GITC[@]}" -C "$d/t1" commit -qam B
  git -C "$d/t1" tag stable
  # the kit's cached vendor clone, as a previous install left it: at A
  git clone -q "$d/t1" "$d/inst/vendor/dark-factory"
  git -C "$d/inst/vendor/dark-factory" checkout -q "$A"
  cp "$INSTALL_SRC" "$d/inst/install.sh"
  jq -n --arg a "$A" --arg t "$2" '{vendorDir:"vendor",
      upstreams:{"dark-factory":({repo:"example/dark-factory",commit:$a} + (if $t == "" then {} else {track:$t} end))},
      install:{skills:[],skillSources:{},hooks:[],hookSources:{}},
      instance:{name:"m",kind:"instance"}}' > "$d/inst/loom.lock.json"
}
run() {  # run <case> [install args...] -- NOT --offline: resolving track needs the (local) remote
  local c="$1"; shift
  ( cd "$WORK/$c/inst" && env -u LOOM_LOCK -u LOOM_FROZEN LOOM_LIVE="$WORK/$c/live" LOOM_BIN="$WORK/$c/bin" \
      GIT_CONFIG_NOSYSTEM=1 bash install.sh --no-prove "$@" 2>&1 )
}
label() { cat "$WORK/$1/inst/boot-kit/scripts/ENGINE_LABEL" 2>/dev/null || echo "<none>"; }

echo "=== T1: track moved -> the engine is the resolved commit on the FIRST install ==="
mk t1 stable
O="$(run t1)"
contains "T1 the engine that RAN is B" "ENGINE=B" "$O"
[ "$(label t1)" = "B" ] && ok "T1 the copied engine is B" || bad "T1 the copied engine is B" "got $(label t1)"
B="$(git -C "$WORK/t1/t1" rev-parse stable)"
contains "T1 the .generated stamp names B" "@ $B" "$(cat "$WORK/t1/inst/boot-kit/scripts/.generated" 2>/dev/null)"

echo "=== T2: --frozen ignores track (control) ==="
mk t2 stable
O="$(run t2 --frozen)"
contains "T2 the engine that RAN is A" "ENGINE=A" "$O"
[ "$(label t2)" = "A" ] && ok "T2 the copied engine is A" || bad "T2 the copied engine is A" "got $(label t2)"

echo "=== T3: no track -> the recorded commit (control) ==="
mk t3 ""
O="$(run t3)"
contains "T3 the engine that RAN is A" "ENGINE=A" "$O"
[ "$(label t3)" = "A" ] && ok "T3 the copied engine is A" || bad "T3 the copied engine is A" "got $(label t3)"

echo "=== T4: a track that resolves to nothing keeps the recorded pin ==="
mk t4 no-such-ref
O="$(run t4)"
contains "T4 the engine that RAN is A" "ENGINE=A" "$O"
[ "$(label t4)" = "A" ] && ok "T4 the copied engine is A" || bad "T4 the copied engine is A" "got $(label t4)"

echo "=== T5: --dry-run says it would resolve, and copies nothing ==="
mk t5 stable
O="$(run t5 --dry-run)"
contains "T5 the plan names the resolution" "would  resolve dark-factory 'stable' before copying the engine" "$O"
[ "$(label t5)" = "<none>" ] && ok "T5 no engine was copied" || bad "T5 no engine was copied" "got $(label t5)"

echo
echo "passed $PASS  failed $FAIL"
echo "ASSERTIONS: $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
