#!/usr/bin/env bash
# Prove the walkthrough suite can FAIL — one deliberate defect at a time.
#
# ⛔ WHY THIS EXISTS, AND WHY IT IS A SEPARATE SUITE. `test-walkthrough-actions.sh` is 103
# green assertions, and a green suite carries no information until you have watched it go
# red on an input it must catch. The repo already holds this argument twice — once in
# `gate-selftest.sh`, which plants a canary per pattern class and runs FIRST in CI for
# exactly this reason, and once in the assertion-count contract in `run-tests.sh`, which
# exists because "asserted 44 things" and "asserted nothing" both exit 0.
#
# It is sharper than usual here. `df-app-walkthrough` shipped SEVEN scripts with no tests
# at all, and the defect that got through in #224 was an all-clear that could not fail:
# a black-frame probe that never ran emitted no matches, and "no matches" was scored
# identically to "nothing wrong". A suite written to catch that class must itself be shown
# to be falsifiable, or it is the same shape one level up.
#
# ⚠️ EACH MUTATION DECLARES THE ASSERTION IT MUST BREAK, and a mutant that fails the suite
# for some OTHER reason is NOT counted as caught. Without that, a mutation that merely
# crashed the driver would score as a win and the specific assertion could be inert.
#
# ⚠️ A MUTATION WHOSE TARGET TEXT IS GONE IS A HARD FAILURE, not a skip. If the subject is
# refactored, a silent no-op mutation would leave this suite green while proving nothing —
# the precise failure mode it was written to rule out.
#
# Needs node only. Mutates a COPY under TMPDIR; the checkout is never written to.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"

command -v node    >/dev/null 2>&1 || { echo "test-walkthrough-mutations: need node"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "test-walkthrough-mutations: need python3"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wtmut.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0

# Replace the FIRST literal occurrence of <old> with <new>, or exit 3 if it is absent.
# Literal, not a regex: these targets contain `?`, `|`, `(`, `.` and quotes, and a regex
# that silently matched nothing is the one outcome this suite must never treat as fine.
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
if old not in src:
    sys.stderr.write("MUTATION TARGET NOT FOUND: %r\n" % (old,))
    sys.exit(3)
open(path, "w").write(src.replace(old, new, 1))
PY
}

# check <label> <relfile> <old> <new> <expected-fail-substring> <driver> [case] [auth]
#
# Builds a fresh copy of the skill, applies one mutation, runs one driver, and requires
# BOTH that the driver fails AND that the named assertion is among the failures.
#
# ⚠️ `auth` is a POSITIONAL argument and not a `VAR=x check …` prefix on purpose. In bash a
# variable assignment prefixed to a FUNCTION call persists after the function returns, so
# one case's auth mode would silently leak into every later case — and since `session.mjs`
# reads WT_AUTH at module load, the leak would change what was measured without changing
# what was printed.
check() {
  local label="$1" relfile="$2" old="$3" new="$4" want="$5" driver="$6" kase="${7:-}" auth="${8:-none}"
  local dir="$T/m$((PASS + FAIL))"
  mkdir -p "$dir"
  cp -R "$SKILL/scripts" "$SKILL/tests" "$dir/"

  if ! mutate "$dir/$relfile" "$old" "$new" 2>"$dir/mut.err"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %-44s could not apply mutation\n' "$label"
    sed 's/^/        | /' "$dir/mut.err"
    return
  fi

  local out rc
  case "$driver" in
    actions) out="$(node "$dir/tests/lib/case-actions.mjs" 2>&1)"; rc=$? ;;
    session) out="$(env -u WT_AUTH -u WT_APP -u WT_STORAGE_STATE -u WT_SIGNIN_PATH \
                      -u CLERK_SECRET_KEY -u CLERK_USER_ID \
                      WT_AUTH="$auth" WT_APP=https://app.invalid \
                      CLERK_SECRET_KEY=not-a-real-key CLERK_USER_ID=not-a-real-user \
                      node "$dir/tests/lib/case-session.mjs" "$kase" 2>&1)"; rc=$? ;;
    *) printf '  FAIL  %-44s unknown driver %s\n' "$label" "$driver"; FAIL=$((FAIL + 1)); return ;;
  esac

  if [ "$rc" -eq 0 ]; then
    # The mutant survived. That is the finding this suite exists to produce.
    FAIL=$((FAIL + 1))
    printf '  SURVIVED  %-40s mutant passed the suite — that assertion is inert\n' "$label"
    return
  fi
  if ! printf '%s\n' "$out" | grep -Fq "$want"; then
    FAIL=$((FAIL + 1))
    printf '  WRONG-FAIL  %-38s suite failed, but not on: %s\n' "$label" "$want"
    printf '%s\n' "$out" | grep -E '^  FAIL' | sed 's/^/        | /' | head -5
    return
  fi
  PASS=$((PASS + 1))
  printf '  caught  %-42s via: %s\n' "$label" "$want"
}

A="scripts/lib/actions.mjs"
S="scripts/lib/session.mjs"

echo "=== the action vocabulary can fail ==="

# ⛔ The #224 defect class, transplanted: an arm that stops refusing. A mutant that returns
# instead of throwing makes a typo'd action type look like a deliberate pause.
check "unknown action type stops refusing" "$A" \
  'throw new Error(`unknown action type: ${a.type}`);' 'return;' \
  'an unknown action type REFUSES' actions

check "empty descriptor stops refusing" "$A" \
  'throw new Error(`action needs one of selector | role | text: ${JSON.stringify(a)}`);' \
  'loc = scope.locator("body");' \
  'a descriptor with no selector, role or text REFUSES' actions

# ⛔ Visible-first collapses to first-match — the defect actions.mjs was written to prevent.
# A hidden twin in an inactive tab panel then answers for the visible control.
check "resolution takes first, not visible" "$A" \
  'for (let i = 0; i < n; i++) {' 'if (n) return loc.nth(0);
  for (let i = 0; i < n; i++) {' \
  'resolution skips a hidden match' actions

# ⛔ Scoping collapses to the page. Same consequence by a different route.
check "scope ignores the tab panel" "$A" \
  'const scope = a.global ? page : await scopeFor(page);' 'const scope = page;' \
  'lookups resolve INSIDE the panel' actions

# ⛔ An explicit nth stops being explicit.
check "nth is ignored" "$A" \
  'const chosen = typeof a.nth === "number" ? loc.nth(a.nth) : null;' 'const chosen = null;' \
  'an explicit nth is honoured' actions

# ⛔ The falsy-vs-absent conflation, in the field where the author got it RIGHT. If this
# mutant survived, the `settle: 0` assertion would be decoration.
check "settle:0 falls through to default" "$A" \
  'const settle = typeof a.settle === "number" ? a.settle : DEFAULT_SETTLE;' \
  'const settle = a.settle || DEFAULT_SETTLE;' \
  'settle:0 means zero' actions

# ⛔ The falsy-vs-absent conflation again, in the field where it was actually WRONG until
# this change: `nameFlags: ""` is the obvious way to ask for a case-sensitive match, and
# `|| "i"` silently handed back "i".
check "nameFlags empty string swallowed" "$A" \
  'typeof a.nameFlags === "string" ? a.nameFlags : "i"' 'a.nameFlags || "i"' \
  'means case-SENSITIVE' actions

# ⛔ A fill with no text types the string "undefined" into the field.
check "fill types undefined" "$A" \
  'await loc.fill(a.text ?? "");' 'await loc.fill(a.text);' \
  'fill with no text clears the field' actions

# ⛔ The card is left up over the step it was meant to introduce.
check "goto leaves the card up" "$A" \
  'case "goto":
      await dropCard(page);' 'case "goto":' \
  'goto drops the card before anything else' actions

# ⛔ point becomes a click — a read-only beat that mutates the app. On a real walkthrough
# against a live tenant this is the most expensive mutant in the list.
check "point clicks" "$A" \
  'const loc = await resolve(page, a);
      await glideTo(page, loc);
      return;' 'const loc = await resolve(page, a);
      await showClick(page, loc);
      return;' \
  'point glides WITHOUT clicking' actions

# ⛔ The resolve ceiling reverts to Playwright's 30s default: half a minute of dead video
# per typo, which is what RESOLVE_TIMEOUT exists to prevent.
check "resolve loses its short ceiling" "$A" \
  'const timeout = a.timeout || RESOLVE_TIMEOUT;' 'const timeout = a.timeout || 30000;' \
  'click waits for visible twice' actions

echo
echo "=== the session helpers can fail ==="

# ⛔ THE TICKET REPLAY. Moving the mint out of the loop retries with a credential the
# server has already burned, so the retry can never succeed — and three attempts still
# happen, so an attempt-count assertion alone would not notice.
check "clerk retry replays one ticket" "$S" \
  'for (let attempt = 1; attempt <= 3; attempt++) {
    const ticket = await mintClerkTicket();' \
  'const ticket = await mintClerkTicket();
  for (let attempt = 1; attempt <= 3; attempt++) {' \
  'each attempt uses a FRESH ticket' session signin-clerk-retry clerk-ticket

# ⛔ The fixed sleep the comment in session.mjs warns against: works until the run where
# the widget is slow, and then the whole recording is of a sign-in page.
check "clerk sleeps instead of waiting" "$S" \
  'await page.waitForURL((u) => !u.toString().includes(signInPath), { timeout: 45000 });' \
  'await page.waitForTimeout(3000);' \
  'waits for the REDIRECT' session signin-clerk-ok clerk-ticket

# ⛔ An unknown auth mode silently records an unauthenticated session.
check "unknown auth mode stops refusing" "$S" \
  'if (AUTH !== "clerk-ticket") throw new Error(`unknown WT_AUTH: ${AUTH}`);' \
  'if (AUTH !== "clerk-ticket") return true;' \
  'an unrecognised WT_AUTH REFUSES' session signin-unknown totally-made-up

# ⛔ storage-state with no path: Playwright opens a signed-OUT context and every beat
# fails one at a time, forty minutes from now.
check "storage-state stops refusing" "$S" \
  'if (!p) throw new Error("storage-state mode needs WT_STORAGE_STATE");' 'if (!p) return opts;' \
  'REFUSES up front' session ctx-storage-missing storage-state

# ⛔ Click before ripple: the video shows an effect with no visible cause.
check "click lands before the ripple" "$S" \
  'await page.waitForTimeout(220);
  }
  await locator.click({ timeout });' \
  'await page.waitForTimeout(220);
  }' \
  'showClick honours an explicit timeout' session glide

# ⛔ glideTo stops guarding a missing bounding box, so the cursor is driven to NaN and
# parks at a stale position for the rest of the recording.
check "glideTo ignores a missing box" "$S" \
  'if (!box) return null;' 'if (!box) return { x: NaN, y: NaN };' \
  'glideTo returns null for an element with no bounding box' session glide

# ⛔ A SYNTAX ERROR IN THE INJECTED SCRIPT. Node never parses this string, so without the
# parse assertion this reaches a browser and fails after the TTS has run.
check "cursor script stops parsing" "$S" \
  'window.__wtMove = (x, y) => {' 'window.__wtMove = (x, y) => {{{' \
  'CURSOR_INIT_SCRIPT parses as JavaScript' session cursor

# ⛔ The ripple stops re-triggering, so only the first click of a run draws one. The
# `remove(); void offsetWidth;` reflow is the whole mechanism and it looks like dead code.
check "ripple does not re-trigger" "$S" \
  "r.classList.remove('__wt_pop'); void r.offsetWidth;" '' \
  'a SECOND ripple removes the class' session cursor

# ⛔ The stylesheet goes inside the card instead of <head> — the mistake showCard's own
# comment records having made, here in the cursor's installer.
check "cursor stylesheet misplaced" "$S" \
  'document.head.appendChild(s);' 'document.body.appendChild(s);' \
  'appends exactly one stylesheet to <head>' session cursor

echo
echo "=== the artefact checks can fail ==="

# These drive `test-walkthrough-verify.sh` over a mutated verify.mjs. They need ffmpeg,
# because a mutation to a probe is only observable against a real artefact.
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
  vcheck() { # vcheck <label> <old> <new> <expected-fail-substring>
    local label="$1" old="$2" new="$3" want="$4"
    local dir="$T/v$((PASS + FAIL))"
    mkdir -p "$dir"
    cp -R "$SKILL/scripts" "$SKILL/tests" "$dir/"
    if ! mutate "$dir/scripts/verify.mjs" "$old" "$new" 2>"$dir/mut.err"; then
      FAIL=$((FAIL + 1))
      printf '  FAIL  %-44s could not apply mutation\n' "$label"
      sed 's/^/        | /' "$dir/mut.err"
      return
    fi
    local out rc
    out="$(bash "$dir/tests/test-walkthrough-verify.sh" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
      FAIL=$((FAIL + 1))
      printf '  SURVIVED  %-40s mutant passed the suite — that assertion is inert\n' "$label"
      return
    fi
    if ! printf '%s\n' "$out" | grep -Fq "$want"; then
      FAIL=$((FAIL + 1))
      printf '  WRONG-FAIL  %-38s suite failed, but not on: %s\n' "$label" "$want"
      printf '%s\n' "$out" | grep -E '^  FAIL' | sed 's/^/        | /' | head -5
      return
    fi
    PASS=$((PASS + 1))
    printf '  caught  %-42s via: %s\n' "$label" "$want"
  }

  # ⛔ #224 ITSELF, PUT BACK. This is the most important mutant in the file: it restores the
  # exact accepted-an-all-black-video defect that shipped, and the suite must go red.
  vcheck "the #224 black-frame defect, restored" \
    '(bd.ran && black.length === 0 ? ok : fail)' '(black.length === 0 ? ok : fail)' \
    'an unrunnable black probe REFUSES to give a verdict'

  # ⛔ The same defect on the loudness branch, where it has never shipped. `lastNumber`
  # returns NaN when the probe produced nothing, and every comparison against NaN is false
  # — so this one is caught by construction. The mutant proves the assertion sees it.
  vcheck "loudness accepts an unmeasurable file" \
    '(lufs >= LUFS_MIN && lufs <= LUFS_MAX ? ok : fail)' \
    '(!Number.isFinite(lufs) || (lufs >= LUFS_MIN && lufs <= LUFS_MAX) ? ok : fail)' \
    'an unrunnable loudness probe REFUSES a verdict'

  vcheck "true peak stops being checked" \
    '(tp <= TP_MAX ? ok : fail)' '(true ? ok : fail)' \
    'a clipping file is REJECTED on a MEASURED true peak'

  # ⛔ A frame count short of the section count reported as fine. This is the shape of the
  # verifier defect found on 2026-10-02: short by three, printing the same green as 52/52.
  vcheck "short frame count reported as fine" \
    '(shots.length === tl.sections.length ? ok : fail)' '(shots.length >= 0 ? ok : fail)' \
    'a section the video does not reach is REJECTED'

  vcheck "recorder problems stop failing" \
    '(problems.length === 0 ? ok : fail)' '(true ? ok : fail)' \
    'a recorder problem is REJECTED'

  vcheck "captions stop being required" \
    '(cues > 0 ? ok : fail)' '(cues >= 0 ? ok : fail)' \
    'a recording with no caption cues is REJECTED'

  vcheck "the exit status stops reflecting failures" \
    'process.exit(fail.length ? 1 : 0);' 'process.exit(0);' \
    'and the run exits non-zero'

  # ⛔ A missing artefact inferred rather than named: verify.mjs would run ffprobe on a
  # path that does not exist and die with a stack trace instead of one clear line.
  vcheck "a missing mp4 stops being named" \
    'console.error("FAIL: no mp4 at " + MP4);' 'console.error("something went wrong");' \
    'and names the path it looked for'
else
  echo "  ⚠️  ffmpeg absent — the 8 verify.mjs mutants did NOT run."
fi

echo
echo "=== the assembly and stage suites can fail ==="

# The general form of vcheck: mutate any file, then run any one of this directory's suites.
scheck() { # scheck <label> <relfile> <old> <new> <expected-fail-substring> <suite>
  local label="$1" relfile="$2" old="$3" new="$4" want="$5" suite="$6"
  local dir="$T/s$((PASS + FAIL))"
  mkdir -p "$dir"
  cp -R "$SKILL/scripts" "$SKILL/tests" "$dir/"
  if ! mutate "$dir/$relfile" "$old" "$new" 2>"$dir/mut.err"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %-44s could not apply mutation\n' "$label"
    sed 's/^/        | /' "$dir/mut.err"
    return
  fi
  local out rc
  out="$(bash "$dir/tests/$suite" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    FAIL=$((FAIL + 1))
    printf '  SURVIVED  %-40s mutant passed %s\n' "$label" "$suite"
    return
  fi
  if ! printf '%s\n' "$out" | grep -Fq -- "$want"; then
    FAIL=$((FAIL + 1))
    printf '  WRONG-FAIL  %-38s failed, but not on: %s\n' "$label" "$want"
    printf '%s\n' "$out" | grep -E '^  FAIL' | sed 's/^/        | /' | head -5
    return
  fi
  PASS=$((PASS + 1))
  printf '  caught  %-42s via: %s\n' "$label" "$want"
}

# ⛔ THE ORDERING BUG, PUT BACK. Hoisting the playwright import above the timing guard is
# the defect this change fixed; the assertion must notice it returning.
scheck "the record guard goes back under the import" "scripts/record-walkthrough.mjs" \
  'const timingPath = join(OUT, "timing.json");' \
  'const { chromium: _early } = await import(join(SKILL, "node_modules/playwright-core/index.mjs"));
const timingPath = join(OUT, "timing.json");' \
  'without a module-resolution stack trace' test-walkthrough-stages.sh

if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
  # ⛔ The pad stops being added, so every beat after the first is paced to speech alone and
  # the narration runs ahead of the video, cumulatively.
  scheck "narration drops the inter-beat pad" "scripts/build-narration.mjs" \
    'offset += speech + PAD_S;' 'offset += speech;' \
    "the second beat starts after the first's total" test-walkthrough-stages.sh

  # ⛔ Speech duration assumed rather than measured — the one thing stage 1 exists to avoid.
  scheck "narration assumes a speech duration" "scripts/build-narration.mjs" \
    'const speech = durationOf(wav);' 'const speech = 4;' \
    "a beat's speech is MEASURED, not assumed" test-walkthrough-stages.sh

  # ⛔ ASS OVERRIDE INJECTION. A caption containing braces stops being text.
  scheck "captions stop stripping ASS braces" "scripts/assemble.mjs" \
    'const esc = (s) => s.replace(/[{}]/g, "").replace(/\r?\n/g, "\\N");' \
    'const esc = (s) => s.replace(/\r?\n/g, "\\N");' \
    'ASS override braces are stripped from captions' test-walkthrough-assemble.sh

  # ⛔ THE LOGIN GOES BACK IN THE VIDEO.
  scheck "the pre-roll stops being trimmed" "scripts/assemble.mjs" \
    'const prefix = tl.videoPrefixSeconds || 0;' 'const prefix = 0;' \
    'the mux seeks past the pre-roll' test-walkthrough-assemble.sh

  # ⛔ The narration gaps collapse, so every beat's audio starts immediately and the whole
  # track drifts against the video it was paced to.
  scheck "narration gaps collapse to zero" "scripts/assemble.mjs" \
    'const gap = Math.max(0, b.startSeconds - cursor);' 'const gap = 0;' \
    'each beat is front-padded by its measured gap' test-walkthrough-assemble.sh

  # ⛔ Beats stop being ordered by measured start, so cues caption the wrong moments.
  scheck "beats stop being sorted by start" "scripts/assemble.mjs" \
    '.sort((a, b) => a.startSeconds - b.startSeconds);' ';' \
    'cues are ordered by measured start, not file order' test-walkthrough-assemble.sh

  # ⛔ THE SIGPIPE BUG check-prereqs.sh DOCUMENTS, restored. `producer | grep -q` makes grep
  # exit on the first hit, the producer takes SIGPIPE, pipefail turns the pipeline non-zero
  # — and a PRESENT filter reports as missing. Only the positive direction catches this,
  # which is exactly why the suite asserts both.
  scheck "check-prereqs regains the SIGPIPE bug" "scripts/check-prereqs.sh" \
    'FILTERS="$(ffmpeg -hide_banner -filters 2>/dev/null || true)"
case "$FILTERS" in
  *" subtitles "*) ok "ffmpeg subtitles filter (libass)" ;;' \
    'if ffmpeg -hide_banner -filters 2>/dev/null | grep -q " subtitles "; then ok "ffmpeg subtitles filter (libass)"; else bad "ffmpeg has no subtitles filter" "x"; fi
case "x" in
  *" subtitles "*) : ;;' \
    'a PRESENT subtitles filter is reported ok' test-walkthrough-stages.sh
else
  echo "  ⚠️  ffmpeg absent — 7 of the 8 mutants in this section did NOT run."
fi

echo
printf 'mutants caught %s  not caught %s\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
