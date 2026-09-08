#!/usr/bin/env bash
# test-prove.sh — behavioural proof for boot-kit/scripts/prove.sh, the mechanical half of
# VALIDATE-INSTALL.md Part 1.
#
# WHY EACH CHECK IS STUBBED THE WAY IT IS. prove.sh always resolves its siblings
# (identify.sh, lock-verify.sh, df-preflight.py, run-tests.sh) beside ITSELF -- there is no
# env override for "use a different identify.sh", on purpose, the same way lock-verify.sh
# itself is never swapped out from under the suites that prove it. So a case that needs a
# sibling to answer differently gets its OWN scratch "engine" directory: a copy of prove.sh
# plus the REAL identify.sh, lock-verify.sh and run-tests.sh, and either the REAL
# df-preflight.py or a tiny stub that prints exactly the ok=/drift=/unknown= line the case
# needs. Nothing here shells out to the real ~/.claude — every fixture gets its own private
# LOOM_LIVE, and df-preflight is stubbed everywhere except where its own behaviour is not
# under test, precisely so this suite never dials a real MCP hub or `gh` looks at a real repo.
#
# identify.sh and lock-verify.sh (outside case 3) run FOR REAL against a real, local, throwaway
# git checkout -- the strongest evidence available that prove.sh's P1/P2 actually drive them,
# not a rewritten stand-in that only agrees with itself.
#
# Usage: bash boot-kit/scripts/tests/test-prove.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SELF/.." && pwd)"
REPO="$(cd "$SCRIPTS/../.." && pwd)"
PROVE_SRC="$SCRIPTS/prove.sh"
IDENTIFY_SRC="$SCRIPTS/identify.sh"
LOCKVERIFY_SRC="$SCRIPTS/lock-verify.sh"
RUNTESTS_SRC="$SCRIPTS/run-tests.sh"
COMMITGATE_SRC="$REPO/skills/agent-notepad/plugin/hooks/commit-gate.sh"
for f in "$PROVE_SRC" "$IDENTIFY_SRC" "$LOCKVERIFY_SRC" "$RUNTESTS_SRC" "$COMMITGATE_SRC"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output" ;; *) ok "$1" ;; esac; }
eqstr()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/testprove.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
GITC=(-c user.email=prove-test@example.com -c user.name=prove-test)

# mk_engine <case> [preflight-variant: clean|unknown3|drift1] — a scratch copy of the real
# engine, so a case can swap ONE sibling for a controlled stub without touching the real one.
mk_engine() {
  local c="$1" variant="${2:-clean}" e="$WORK/$1/engine"
  mkdir -p "$e"
  cp "$PROVE_SRC" "$e/prove.sh"
  cp "$IDENTIFY_SRC" "$e/identify.sh"
  cp "$LOCKVERIFY_SRC" "$e/lock-verify.sh"
  cp "$RUNTESTS_SRC" "$e/run-tests.sh"
  case "$variant" in
    clean)
      printf '#!/usr/bin/env python3\nprint("preflight now  ok=1 drift=0 unknown=0")\n' > "$e/df-preflight.py"
      ;;
    unknown3)
      printf '#!/usr/bin/env python3\nprint("preflight now  ok=1 drift=0 unknown=3")\n' > "$e/df-preflight.py"
      ;;
    drift1)
      printf '#!/usr/bin/env python3\nprint("preflight now  ok=1 drift=1 unknown=0")\nprint("── DRIFT ──")\nprint("  fake       thing   a fabricated drift row for the suite")\nprint("")\n' > "$e/df-preflight.py"
      ;;
  esac
  chmod +x "$e"/*.sh "$e"/*.py 2>/dev/null
}

# mk_fixture <case> <install-json> — a real, local, offline "Tier 1" (so lock-verify's L1-L3
# have something to check) plus a fresh lockfile carrying the given install block. A
# defaultProfile that matches no real MCP server keeps df-preflight -- when it is the REAL
# script and not a stub -- from probing anything live, but every case here stubs it anyway;
# this is a second line of defence, not the only one.
mk_fixture() {
  local c="$1" ins="$2" d="$WORK/$1"
  mkdir -p "$d/vendor/dark-factory" "$d/live/hooks"
  git -C "$d/vendor/dark-factory" init -q
  echo x > "$d/vendor/dark-factory/seed"
  git "${GITC[@]}" -C "$d/vendor/dark-factory" add -A
  git "${GITC[@]}" -C "$d/vendor/dark-factory" commit -q -m seed
  local commit
  commit="$(git -C "$d/vendor/dark-factory" rev-parse HEAD)"
  jq -n --arg commit "$commit" --argjson inst "$ins" \
    '{vendorDir:"vendor", defaultProfile:"prove-test-nonexistent-estate",
      upstreams:{"dark-factory":{repo:"example/dark-factory",commit:$commit}},
      install:$inst}' > "$d/loom.lock.json"
  # A settings.json with no hooks wired is still a settings.json -- lock-verify's L9 treats
  # its ABSENCE as "NOTHING is wired" and drifts on it, which is a true finding about a
  # fixture that never created the file, not about prove.sh. wire_settings overwrites this
  # for cases that need a hook actually wired.
  printf '{"hooks":{}}\n' > "$d/live/settings.json"
}

hook_file() { # <case> <name> <content>
  printf '%s' "$3" > "$WORK/$1/live/hooks/$2"
  chmod +x "$WORK/$1/live/hooks/$2"
}
wire_settings() { # <case> <hook-name>
  jq -n --arg cmd "$WORK/$1/live/hooks/$2" \
    '{hooks:{PreToolUse:[{hooks:[{type:"command",command:$cmd}]}]}}' \
    > "$WORK/$1/live/settings.json"
}
set_identity() { # <case> <lockfile-identity-json>
  local d="$WORK/$1" tmp
  tmp="$d/loom.lock.json.tmp"
  jq --argjson id "$2" '.install.identity = $id' "$d/loom.lock.json" > "$tmp" && mv "$tmp" "$d/loom.lock.json"
}

run_prove() { # <case> [extra prove.sh args...]
  local c="$1"; shift
  ( cd "$WORK/$c" && LOOM_LIVE="$WORK/$c/live" bash "$WORK/$c/engine/prove.sh" --lock loom.lock.json "$@" 2>&1 )
}
rc_prove() {
  local c="$1"; shift
  ( cd "$WORK/$c" && LOOM_LIVE="$WORK/$c/live" bash "$WORK/$c/engine/prove.sh" --lock loom.lock.json "$@" >/dev/null 2>&1 )
  echo $?
}
p3b_block() { printf '%s\n' "$1" | awk '/^\[P3b\]/{p=1} p{print} /^$/{if(p)exit}'; }

echo "=== 1: a green fixture -> PROVE: PASS, exit 0 ==="
mk_engine green clean
mk_fixture green '{"skills":[],"skillSources":{},"hooks":["a.sh"],"hookSources":{"a.sh":"upstream:hooks/a.sh"}}'
hook_file green a.sh $'#!/usr/bin/env bash\ncat >/dev/null\necho {}\nexit 0\n'
wire_settings green a.sh
OUT1="$(run_prove green --no-tests)"
contains "1: overall verdict is PASS" "=== PROVE: PASS" "$OUT1"
contains "1: P1 passed"              "PASS  identify.sh" "$OUT1"
contains "1: P2 passed"              "PASS  RESULT: LOCKED" "$OUT1"
contains "1: P3 passed"              "PASS  1 wired, declared hook(s) ran clean" "$OUT1"
eqstr    "1: exit code is 0" "0" "$(rc_prove green --no-tests)"

echo ""
echo "=== 2: identity mismatch -> FAIL naming P1 ==="
mk_engine idmismatch clean
mk_fixture idmismatch '{"skills":[],"skillSources":{},"hooks":[],"hookSources":{}}'
set_identity idmismatch '{"hostname":"definitely-not-this-host-xyz"}'
OUT2="$(run_prove idmismatch --no-tests)"
contains "2: FAIL naming P1 identity" "FAIL  identify.sh exit 3" "$OUT2"
contains "2: quotes the DIFFERENT MACHINE line" "DIFFERENT MACHINE" "$OUT2"
contains "2: overall verdict is FAIL" "=== PROVE: FAIL" "$OUT2"
contains "2: verdict names P1" "P1 identity" "$OUT2"
eqstr    "2: exit code is 1" "1" "$(rc_prove idmismatch --no-tests)"

echo ""
echo "=== 3: lock-verify stub prints RESULT: DRIFT -> FAIL naming P2, DRIFT lines repeated ==="
mk_engine lvdrift clean
mk_fixture lvdrift '{"skills":[],"skillSources":{},"hooks":[],"hookSources":{}}'
cat > "$WORK/lvdrift/engine/lock-verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "[L1] fake layer"
echo "DRIFT L1 fabricated drift line for the suite"
echo "=== RESULT: DRIFT ==="
exit 1
EOF
chmod +x "$WORK/lvdrift/engine/lock-verify.sh"
OUT3="$(run_prove lvdrift --no-tests)"
contains "3: FAIL naming P2 lock-verify" "FAIL  lock-verify reported DRIFT" "$OUT3"
contains "3: verdict names P2" "P2 lock-verify" "$OUT3"
contains "3: the DRIFT line is repeated" "DRIFT L1 fabricated drift line for the suite" "$OUT3"

echo ""
echo "=== 4: a wired hook prints not-json -> FAIL naming that hook ==="
mk_engine badjson clean
mk_fixture badjson '{"skills":[],"skillSources":{},"hooks":["bad.sh"],"hookSources":{"bad.sh":"upstream:hooks/bad.sh"}}'
hook_file badjson bad.sh $'#!/usr/bin/env bash\ncat >/dev/null\necho "{\\"decision\\": not json"\nexit 0\n'
wire_settings badjson bad.sh
OUT4="$(run_prove badjson --no-tests)"
contains "4: FAIL names the hook and the reason" "bad.sh: printed non-JSON stdout" "$OUT4"
contains "4: verdict names P3" "P3 hooks runnable" "$OUT4"
contains "4: overall verdict is FAIL" "=== PROVE: FAIL" "$OUT4"

echo ""
echo "=== 4b: a wired hook that prints PLAIN TEXT is runnable, not a failure ==="
# SessionStart and UserPromptSubmit hooks add plain stdout as context; that is a contract,
# not a defect. Only output that starts like JSON and does not parse is judged.
mk_engine plaintext clean
mk_fixture plaintext '{"skills":[],"skillSources":{},"hooks":["prose.sh"],"hookSources":{"prose.sh":"upstream:hooks/prose.sh"}}'
hook_file plaintext prose.sh $'#!/usr/bin/env bash\ncat >/dev/null\necho "agent-notepad continuity: rewrite NOTES.md now"\nexit 0\n'
wire_settings plaintext prose.sh
OUT4B="$(run_prove plaintext --no-tests)"
contains "4b: P3 passes with the prose hook counted as wired" "1 wired, declared hook(s) ran clean" "$OUT4B"
absent   "4b: no non-JSON complaint" "printed non-JSON stdout" "$OUT4B"

echo ""
echo "=== 5: a compound-bash stub allows && -> FAIL not gating ==="
mk_engine compoundallow clean
mk_fixture compoundallow '{"skills":[],"skillSources":{},"hooks":["fake-compound-bash.sh"],"hookSources":{"fake-compound-bash.sh":"upstream:hooks/fake-compound-bash.sh"}}'
hook_file compoundallow fake-compound-bash.sh $'#!/usr/bin/env bash\ncat >/dev/null\necho {}\nexit 0\n'
wire_settings compoundallow fake-compound-bash.sh
OUT5="$(run_prove compoundallow --no-tests)"
contains "5: P3a ran"                  "[P3a] positive control, compound-bash" "$OUT5"
contains "5: FAIL not gating"          "FAIL  gate present, not gating" "$OUT5"
contains "5: verdict names P3a"        "P3a compound-bash" "$OUT5"

echo ""
echo "=== 6: commit-gate -- a stub that fails open, then the REAL gate on the same shape ==="
mk_engine cgstub clean
mk_fixture cgstub '{"skills":[],"skillSources":{},"hooks":["fake-commit-gate.sh"],"hookSources":{"fake-commit-gate.sh":"upstream:hooks/fake-commit-gate.sh"}}'
hook_file cgstub fake-commit-gate.sh $'#!/usr/bin/env bash\ncat >/dev/null\necho {}\nexit 0\n'
wire_settings cgstub fake-commit-gate.sh
OUT6A="$(run_prove cgstub --no-tests)"
contains "6a: P3b ran"                     "[P3b] positive control, commit-gate" "$OUT6A"
contains "6a: FAIL naming P3b"             "FAIL  commit gate fails open for plain git commit" "$OUT6A"
contains "6a: verdict names P3b"           "P3b commit-gate" "$OUT6A"

mk_engine cgreal clean
mk_fixture cgreal '{"skills":[],"skillSources":{},"hooks":["commit-gate.sh"],"hookSources":{"commit-gate.sh":"upstream:hooks/commit-gate.sh"}}'
cp "$COMMITGATE_SRC" "$WORK/cgreal/live/hooks/commit-gate.sh"
chmod +x "$WORK/cgreal/live/hooks/commit-gate.sh"
wire_settings cgreal commit-gate.sh
OUT6B="$(run_prove cgreal --no-tests)"
P3B_BLOCK="$(p3b_block "$OUT6B")"
contains "6b: the REAL gate on the same fixture shape passes P3b" "PASS  plain git commit with a stale context store was blocked" "$P3B_BLOCK"
absent   "6b: no FAIL inside the P3b block" "FAIL" "$P3B_BLOCK"
contains "6b: overall verdict is PASS" "=== PROVE: PASS" "$OUT6B"

echo ""
echo "=== 7: preflight stub -- unknown=3 is a PASS that says so; drift=1 is a FAIL ==="
mk_engine pfunk unknown3
mk_fixture pfunk '{"skills":[],"skillSources":{},"hooks":[],"hookSources":{}}'
OUT7A="$(run_prove pfunk --no-tests)"
contains "7a: PASS carries the unknown count" "PASS  df-preflight: ok=1 drift=0 unknown=3 (3 unknown)" "$OUT7A"
contains "7a: overall verdict is PASS" "=== PROVE: PASS" "$OUT7A"

mk_engine pfdrift drift1
mk_fixture pfdrift '{"skills":[],"skillSources":{},"hooks":[],"hookSources":{}}'
OUT7B="$(run_prove pfdrift --no-tests)"
contains "7b: FAIL naming P4" "FAIL  df-preflight: ok=1 drift=1 unknown=0" "$OUT7B"
contains "7b: verdict names P4" "P4 preflight" "$OUT7B"
contains "7b: the drift row is shown" "fabricated drift row for the suite" "$OUT7B"
contains "7b: overall verdict is FAIL" "=== PROVE: FAIL" "$OUT7B"

echo ""
echo "=== 8: --no-tests skips P5 and says so ==="
OUT8="$(run_prove green --no-tests)"
contains "8: P5 reports SKIPPED"        "SKIPPED  --no-tests" "$OUT8"
absent   "8: the real run-tests.sh was never invoked" "run-tests: discovered" "$OUT8"

echo ""
printf 'prove.sh suite: %d ok, %d failed\n' "$PASS" "$FAIL"
# run-tests.sh treats a suite that exits 0 with no declared count as UNMEASURED, not a pass.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
