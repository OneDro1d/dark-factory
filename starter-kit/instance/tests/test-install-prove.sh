#!/usr/bin/env bash
# test-install-prove.sh — install.sh's new step between `verify` and `not restorable`: it
# runs prove.sh from the materialised engine unless `--no-prove`, and a prove FAIL costs the
# exit code without aborting the remaining steps.
#
# WHY A SEPARATE SUITE FROM test-install-plugins.sh / test-install-marketplace-plugins.sh.
# Those two now pass `--no-prove` on every call precisely so an absent prove.sh in THEIR
# fixture (they were never testing this step) does not confound their own RC assertions.
# This suite is the one that actually builds a fixture T1 carrying prove.sh, so the step it
# wires can run for real.
#
# HOW THE FIXTURE IS BUILT. `mk_instance` follows the same shape as the sibling suites'
# (a real, local, offline git repo standing in for Tier 1, plus a fresh instance root
# carrying `install.sh` copied verbatim from THIS repo). The difference is what T1's
# `boot-kit/scripts/` carries: the REAL prove.sh and identify.sh (both network-free and
# side-effect-free by construction), a STUB lock-verify.sh and a STUB df-preflight.py (the
# same convention the marketplace-plugins suite uses for the Claude CLI -- a suite that
# shelled out to the real preflight would probe this machine's real MCP hubs and `gh`
# identity), the REAL run-tests.sh, and one trivial `tests/test-fixture-noop.sh` so P5 has
# something to discover and pass. Every run pins LOOM_LIVE/LOOM_BIN into the fixture so
# nothing here can reach the real ~/.claude or ~/.local/bin -- prove.sh's own PROVE_SETTINGS
# default falls back to $LOOM_LIVE/settings.json, and an unredirected LOOM_LIVE would let it
# fall further, to the real ~/.claude/settings.json.
#
# Usage: bash starter-kit/instance/tests/test-install-prove.sh
# Exit:  0 = every case behaves   1 = at least one does not   2 = harness could not run
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"
REPO="$(cd "$KIT/../.." && pwd)"
INSTALL_SRC="$KIT/install.sh"
PROVE_SRC="$REPO/boot-kit/scripts/prove.sh"
IDENTIFY_SRC="$REPO/boot-kit/scripts/identify.sh"
RUNTESTS_SRC="$REPO/boot-kit/scripts/run-tests.sh"
for f in "$INSTALL_SRC" "$PROVE_SRC" "$IDENTIFY_SRC" "$RUNTESTS_SRC"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done
command -v jq  >/dev/null 2>&1 || { echo "jq required";  exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "'$2' not in output" ;; esac; }
absent()   { case "$3" in *"$2"*) bad "$1" "'$2' unexpectedly in output" ;; *) ok "$1" ;; esac; }
eqnum()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/instprove.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
GITC=(-c user.email=test@example.com -c user.name=test)

# mk_instance <case> <install-json> — a fixture "Tier 1" carrying a REAL prove.sh + identify.sh,
# a fast no-op lock-verify.sh and df-preflight.py stub (so lock-verify/preflight cannot reach
# this machine's real state), the real run-tests.sh, and one trivial passing suite so P5 has
# something to discover. Plus a fresh instance root with the given `install` block.
mk_instance() {
  local c="$1" ins="$2" d="$WORK/$1"
  mkdir -p "$d/inst" "$d/t1/boot-kit/scripts/tests"
  cp "$PROVE_SRC" "$d/t1/boot-kit/scripts/prove.sh"
  cp "$IDENTIFY_SRC" "$d/t1/boot-kit/scripts/identify.sh"
  cp "$RUNTESTS_SRC" "$d/t1/boot-kit/scripts/run-tests.sh"
  cat > "$d/t1/boot-kit/scripts/lock-verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "RESULT: LOCKED (fixture stub)"
echo "=== RESULT: LOCKED (fixture stub) ==="
exit 0
EOF
  cat > "$d/t1/boot-kit/scripts/df-preflight.py" <<'EOF'
#!/usr/bin/env python3
print("preflight now  ok=1 drift=0 unknown=0")
EOF
  cat > "$d/t1/boot-kit/scripts/tests/test-fixture-noop.sh" <<'EOF'
#!/usr/bin/env bash
echo "fixture noop suite ran"
echo "ASSERTIONS: 1"
exit 0
EOF
  # A stand-in validate.sh: the installer's closing box keys on this FILE existing in the
  # materialised engine (never executed here), so the "one command" branch can be observed.
  printf '#!/usr/bin/env bash\necho "fixture validate.sh — never run by the suite"\n' \
    > "$d/t1/boot-kit/scripts/validate.sh"
  chmod +x "$d/t1/boot-kit/scripts"/*.sh "$d/t1/boot-kit/scripts"/*.py \
           "$d/t1/boot-kit/scripts/tests"/*.sh
  git -C "$d/t1" init -q
  git "${GITC[@]}" -C "$d/t1" add -A
  git "${GITC[@]}" -C "$d/t1" commit -q -m fixture
  mkdir -p "$d/inst/vendor"
  git clone -q "$d/t1" "$d/inst/vendor/dark-factory"
  cp "$INSTALL_SRC" "$d/inst/install.sh"
  jq -n --argjson inst "$ins" \
    '{vendorDir:"vendor", upstreams:{"dark-factory":{repo:"example/dark-factory",commit:""}}, install:$inst}' \
    > "$d/inst/loom.lock.json"
}

# run <case> [extra install.sh args...] — always --offline; LOOM_LIVE/LOOM_BIN pinned inside
# the fixture so nothing here can reach the real ~/.claude or ~/.local/bin.
run() {
  local c="$1"; shift
  ( cd "$WORK/$c/inst" \
      && LOOM_LIVE="$WORK/$c/inst/live" LOOM_BIN="$WORK/$c/inst/bin" \
         bash install.sh --offline "$@" 2>&1 )
}
rc_of() {
  local c="$1"; shift
  ( cd "$WORK/$c/inst" \
      && LOOM_LIVE="$WORK/$c/inst/live" LOOM_BIN="$WORK/$c/inst/bin" \
         bash install.sh --offline "$@" >/dev/null 2>&1 )
  echo $?
}

DECL='{"skills":[],"skillSources":{},"hooks":[],"hookSources":{}}'

echo "=== A: install.sh --offline reaches the prove step and runs it ==="
mk_instance a "$DECL"
OUT_A="$(run a)"
contains "A the prove step header is printed" \
  "prove — the install is not done until this passes" "$OUT_A"
contains "A prove.sh actually ran (its own === prove === header)" "=== prove ===" "$OUT_A"
contains "A P1 identity ran"  "[P1] identity"  "$OUT_A"
contains "A P2 lock-verify ran and read the fixture stub's verdict" \
  "PASS  RESULT: LOCKED (fixture stub)" "$OUT_A"
contains "A P5 discovered and ran the fixture's own trivial suite" \
  "PASS  === 1 passed" "$OUT_A"
contains "A prove's own overall verdict is printed" "=== PROVE: PASS" "$OUT_A"
RC_A="$(rc_of a)"
eqnum "A a clean install with a proving prove.sh exits 0" "0" "$RC_A"

echo "=== B: --no-prove prints the skip line and does not run prove.sh ==="
mk_instance b "$DECL"
OUT_B="$(run b --no-prove)"
contains "B the prove step header still prints (the step always runs; --no-prove changes what it does inside)" \
  "prove — the install is not done until this passes" "$OUT_B"
contains "B says it was skipped, and how to run it by hand" \
  "SKIPPED  --no-prove. Run it by hand any time:" "$OUT_B"
contains "B names the exact command to run it by hand" \
  "prove.sh --lock" "$OUT_B"
absent   "B prove.sh's own header never printed -- it did not run" "=== prove ===" "$OUT_B"
absent   "B no [P1] check ran" "[P1] identity" "$OUT_B"
RC_B="$(rc_of b --no-prove)"
eqnum "B --no-prove still exits 0 (nothing else in this fixture drifts)" "0" "$RC_B"

echo "=== C: the closing box names the ONE COMMAND whenever the engine carries validate.sh ==="
# ⛔ MEASURED 2026-09-09 across the four shared team kits: none has VALIDATE-INSTALL.md at its
# root (the document ships inside the Tier-1 pin), so the box was keyed on a file no minted kit
# has and printed the WARN instead of the command. Red against the previous tree: C1, C2.
contains "C1 the box prints the one command" "NEXT STEP, and it is one command:" "$OUT_A"
contains "C2 and it names the materialised validate.sh with --kit-root" "boot-kit/scripts/validate.sh --kit-root " "$OUT_A"
absent   "C3 no 'no VALIDATE-INSTALL.md' WARN when the command exists" "no VALIDATE-INSTALL.md" "$OUT_A"
mk_instance c "$DECL"
rm -f "$WORK/c/inst/vendor/dark-factory/boot-kit/scripts/validate.sh"
OUT_C="$(run c)"
absent   "C4 a pin without validate.sh does not claim one command" "NEXT STEP, and it is one command:" "$OUT_C"
contains "C5 it says the engine lacks validate.sh and that vendor/ is incomplete, not that the step is optional" "no validate.sh in the materialised engine" "$OUT_C"
mkdir -p "$WORK/c/inst/vendor/dark-factory/starter-kit/instance"
printf '# fixture doc\n' > "$WORK/c/inst/vendor/dark-factory/starter-kit/instance/VALIDATE-INSTALL.md"
OUT_C2="$(run c)"
contains "C6 an old pin that still ships the document gets the by-hand NEXT STEP" "this pin predates validate.sh" "$OUT_C2"
contains "C7 naming the document inside the pin" "starter-kit/instance/VALIDATE-INSTALL.md" "$OUT_C2"
# A dry run materialises no engine, so the file is absent by design; the box must speak in the
# dry run's voice, not raise the incomplete-vendor WARN. Red against the previous tree: C8, C9.
OUT_A_DRY="$(run a --dry-run)"
contains "C8 --dry-run says what WOULD print, naming validate.sh" "would  print the NEXT STEP: " "$OUT_A_DRY"
absent   "C9 --dry-run raises no incomplete-vendor WARN" "no validate.sh in the materialised engine" "$OUT_A_DRY"

echo "=== D: a kit marked kind=template is told so; an instance (or no marker) is not ==="
# UPSTREAMED from the four shared team kits, whose installer carried the block while this file
# did not. Red against the previous tree: D1, D2.
mk_instance d "$DECL"
jq '.instance = {name: "shared-kit", kind: "template"}' "$WORK/d/inst/loom.lock.json" > "$WORK/d/inst/lock.tmp"
mv "$WORK/d/inst/lock.tmp" "$WORK/d/inst/loom.lock.json"
OUT_D="$(run d)"
contains "D1 a template kit is told it is not yet the reader's" "THIS IS A TEMPLATE KIT, NOT YET YOURS." "$OUT_D"
contains "D2 and how to make it theirs (flip the marker)" 'flip the marker' "$OUT_D"
RC_D="$(rc_of d)"
eqnum    "D3 a template kit still INSTALLS (warn, never block)" "0" "$RC_D"
absent   "D4 no marker at all (bootstrap's instance) prints no template warning" "THIS IS A TEMPLATE KIT" "$OUT_A"
mk_instance e "$DECL"
jq '.instance = {name: "mine", kind: "instance"}' "$WORK/e/inst/loom.lock.json" > "$WORK/e/inst/lock.tmp"
mv "$WORK/e/inst/lock.tmp" "$WORK/e/inst/loom.lock.json"
OUT_E="$(run e)"
absent   "D5 kind=instance prints no template warning" "THIS IS A TEMPLATE KIT" "$OUT_E"

echo ""
printf 'install.sh prove step: %d ok, %d failed\n' "$PASS" "$FAIL"
# run-tests.sh treats a suite that exits 0 with no declared count as UNMEASURED, not a pass.
printf 'ASSERTIONS: %d\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
