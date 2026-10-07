#!/usr/bin/env bash
# The part of df-app-walkthrough that needs a REAL browser: the drawn cursor, where a click
# actually lands, visible-first resolution against real layout, and recordVideo.
#
# ⛔ READ THIS BEFORE "FIXING" THE SKIP. Every other suite here is node-only on purpose, and
# `tests/README.md` lists what that leaves uncovered. This suite is those lines. It cannot be
# node-only, so it SKIPS when Chromium is absent rather than failing — and refuses when the
# caller said a degraded run is unacceptable:
#
#   unset WT_TESTS_REQUIRE_FULL  → missing chromium prints a COVERAGE line and exits 0
#   WT_TESTS_REQUIRE_FULL=1      → missing chromium exits 1 and names what is missing
#
# ⚠️ WT_TESTS_REQUIRE_FULL IS SET IN THE GATE JOB, so enrolling this suite means the gate
# MUST install the browser (`gate.yml` already installs ffmpeg for exactly this reason:
# measured 2026-10-05, the runner ships none and four suites went green at a fraction of
# their coverage). If you add this file without the install step, the gate goes RED — which
# is the correct failure, and the whole point of the interlock.
#
# ⚠️ Playwright does NOT encode video with the system ffmpeg; it pipes screencast frames to
# its own pinned build, a SEPARATE download from the browser. A machine with a perfect
# `ffmpeg` on PATH can still fail the video case, so the precondition checks for both.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
LIB="$HERE/lib"
PW="$SKILL/node_modules/playwright-core"

TOTAL=0
FAILED=0
MISSING=()

command -v node    >/dev/null 2>&1 || MISSING+=("node")
command -v ffprobe >/dev/null 2>&1 || MISSING+=("ffprobe (system, for probing the webm)")
[ -d "$PW" ]       || MISSING+=("playwright-core (run scripts/setup.sh)")

# The browser and Playwright's bundled ffmpeg live in its own cache, not on PATH. Ask
# playwright-core where they are rather than guessing a path that changes with every release.
if [ -d "$PW" ]; then
  node -e 'import("'"$PW"'/index.mjs").then(async (m) => { const b = await m.chromium.launch(); await b.close(); }).catch((e) => { console.error(String(e.message).split("\n")[0]); process.exit(1); })' \
    >/dev/null 2>&1 || MISSING+=("a launchable chromium (node node_modules/playwright-core/cli.js install chromium)")
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
  if [ "${WT_TESTS_REQUIRE_FULL:-}" = "1" ]; then
    echo "test-walkthrough-browser: REFUSING a degraded run — WT_TESTS_REQUIRE_FULL=1 and missing:"
    for m in "${MISSING[@]}"; do echo "  - $m"; done
    exit 1
  fi
  echo "COVERAGE: test-walkthrough-browser SKIPPED ENTIRELY — missing: ${MISSING[*]}"
  echo "COVERAGE: the real-browser gaps in tests/README.md stay unproven on this machine."
  echo "ASSERTIONS: 0"
  exit 0
fi

# run <label> <case>
#
# ⚠️ Exit status is read from NODE, never from a pipeline — piping node through grep reports
# GREP's status, a number that looks like a verdict and measures nothing. And a case that
# asserts ZERO things is a FAILURE here: every case body is gated on its name, so a typo
# would otherwise run nothing and report the same green as a pass.
run() {
  local label="$1" case_name="$2"
  local out rc n
  out="$(node "$LIB/case-browser.mjs" "$case_name" 2>&1)"; rc=$?
  n="$(printf '%s\n' "$out" | grep -Eo '^ASSERTIONS: [0-9]+$' | tail -1 | tr -cd '0-9')"
  : "${n:=0}"
  TOTAL=$((TOTAL + n))
  if [ "$rc" -eq 0 ] && [ "$n" -gt 0 ]; then
    printf '  PASS  %-34s %s assertions\n' "$label" "$n"
  else
    FAILED=$((FAILED + 1))
    printf '  FAIL  %-34s rc=%s assertions=%s\n' "$label" "$rc" "$n"
    printf '%s\n' "$out" | sed 's/^/        | /'
  fi
}

echo "=== df-app-walkthrough — the drawn cursor, in a real browser ==="
run "cursor installs"               cursor-install
run "cursor survives an SPA wipe"   cursor-reinstall

echo
echo "=== df-app-walkthrough — where the cursor is and where it clicks ==="
run "glideTo hits the real centre"  glide-centre
run "click lands where drawn"       click-lands-where-drawn
run "ripple re-triggers"            ripple-retriggers

echo
echo "=== df-app-walkthrough — resolution against real layout ==="
run "visible tabpanel wins"         visible-tabpanel
run "nameFlags case sensitivity"    nameflags
run "card renders text, not HTML"   card

echo
echo "=== df-app-walkthrough — the recording, and the stub's own premise ==="
run "recordVideo writes a webm"     record-video
run "stub matches real Playwright"  stub-fidelity

echo
printf 'cases failed: %s\n' "$FAILED"
printf 'ASSERTIONS: %s\n' "$TOTAL"
[ "$FAILED" -eq 0 ] || exit 1
