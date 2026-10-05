#!/usr/bin/env bash
# The remaining three scripts: `build-narration.mjs` (stage 1), `record-walkthrough.mjs`
# (stage 2, its preconditions only) and `check-prereqs.sh`.
#
# ⛔ WHY THE GUARDS ARE WORTH A TEST AT ALL. This pipeline is four stages long and each one
# consumes the previous one's output. A stage that starts without its input and fails deep
# inside — or worse, half-succeeds — costs a TTS run and a browser session before anybody
# learns the first stage never ran. Each guard is one line of code and the only thing that
# turns a stack trace into an instruction.
#
# ⛔ ONE OF THESE GUARDS WAS UNREACHABLE, and no test existed to notice. In
# `record-walkthrough.mjs` the playwright import sat ABOVE the timing.json check, so on a
# fresh checkout — the exact case the message exists for — node threw ERR_MODULE_NOT_FOUND
# and printed a stack trace instead. Fixed in the same change as this suite, and both
# preconditions are asserted below.
#
# ⚠️ WHAT IS NOT COVERED: the real TTS (a model download), and the recording loop itself
# (a browser). `build-narration.mjs` is driven with a stub voice that emits a real wav, so
# the PACING arithmetic is measured for real while the synthesis is not.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "test-walkthrough-stages: need node"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wtstage.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -Fq -- "$3"; then ok "$1"; else bad "$1" "[$2] lacks [$3]"; fi; }
fails() { if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1" "exited 0"; fi; }

echo "=== build-narration.mjs — preconditions ==="
mkdir -p "$T/bn"
OUT="$(WT_OUT="$T/bn" WT_NARRATION="$T/bn/absent.json" node "$SKILL/scripts/build-narration.mjs" 2>&1)"
RC=$?
fails "no narration file: refuses" "$RC"
has "…names the path it looked for" "$OUT" "$T/bn/absent.json"
has "…and points at the template" "$OUT" "templates/narration.example.json"

printf '{"sections":[]}\n' > "$T/bn/narration.json"
OUT="$(WT_OUT="$T/bn" WT_NARRATION="$T/bn/narration.json" WT_PIPER_PYTHON="$T/bn/no-such-piper" \
       node "$SKILL/scripts/build-narration.mjs" 2>&1)"
RC=$?
fails "no TTS engine: refuses" "$RC"
has "…and points at setup.sh" "$OUT" "scripts/setup.sh"

echo
echo "=== record-walkthrough.mjs — preconditions ==="
mkdir -p "$T/rec"
OUT="$(WT_OUT="$T/rec" node "$SKILL/scripts/record-walkthrough.mjs" 2>&1)"
RC=$?
fails "no timing.json: refuses" "$RC"
has "…and points at build-narration.mjs" "$OUT" "run build-narration.mjs first"
# ⛔ THE REGRESSION GUARD FOR THE ORDERING BUG. If the playwright import is ever hoisted
# back above the timing check, this assertion fails: the message becomes a stack trace.
if printf '%s' "$OUT" | grep -q 'ERR_MODULE_NOT_FOUND'; then
  bad "…without a module-resolution stack trace" "the guard is below the playwright import again"
else
  ok "…without a module-resolution stack trace"
fi

# With timing.json present but playwright absent, the OTHER precondition must report.
printf '{"sections":[],"totalSeconds":0}\n' > "$T/rec/timing.json"
OUT="$(WT_OUT="$T/rec" node "$SKILL/scripts/record-walkthrough.mjs" 2>&1)"
RC=$?
if [ -d "$SKILL/node_modules/playwright-core" ]; then
  ok "playwright is installed here, so its guard cannot be exercised (declared, not skipped)"
else
  fails "no playwright-core: refuses" "$RC"
  has "…and points at setup.sh" "$OUT" "run scripts/setup.sh"
fi

HAVE_FF=0
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then HAVE_FF=1; fi

if [ "$HAVE_FF" -eq 0 ] && [ -n "${WT_TESTS_REQUIRE_FULL:-}" ]; then
  echo
  echo "REFUSING TO DEGRADE: WT_TESTS_REQUIRE_FULL is set and ffmpeg/ffprobe is absent."
  echo "  The build-narration pacing arithmetic would not run, nor the positive"
  echo "  check-prereqs direction that proves the SIGPIPE repair works."
  echo "  Install ffmpeg, or unset WT_TESTS_REQUIRE_FULL to accept reduced coverage knowingly."
  printf 'ASSERTIONS: %s\n' "$((PASS + FAIL))"
  exit 1
fi

if [ "$HAVE_FF" -eq 1 ]; then
  echo
  echo "=== build-narration.mjs — the pacing arithmetic ==="
  # ⛔ THIS IS WHY AUDIO IS BUILT BEFORE VIDEO. Every beat's TRUE spoken duration has to be
  # known before the browser opens, because you cannot pace a step to a sentence whose
  # length you have not measured. The offsets below are accumulated from REAL ffprobe
  # measurements of real wavs; only the synthesis is stubbed.
  mkdir -p "$T/voices"
  ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i "sine=f=440:d=2" "$T/two.wav"
  # A stub "piper": consumes the text on stdin and writes a 2s wav to the -f path.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cat > /dev/null\n'
    printf 'out=""\n'
    printf 'while [ $# -gt 0 ]; do\n'
    printf '  if [ "$1" = "-f" ]; then out="$2"; fi\n'
    printf '  shift\n'
    printf 'done\n'
    printf 'cp %s "$out"\n' "$T/two.wav"
  } > "$T/piper"
  chmod +x "$T/piper"

  mkdir -p "$T/nar"
  cat > "$T/nar/narration.json" <<'JSON'
{
  "voice": "en_US-lessac-medium",
  "sections": [
    { "id": "intro", "title": "Intro",
      "beats": [
        { "say": "one",  "caption": "c1", "action": { "type": "goto", "url": "x" } },
        { "say": "two",  "caption": "c2" }
      ] },
    { "id": "outro",
      "beats": [ { "caption": "c3" } ] }
  ]
}
JSON
  OUT="$(WT_OUT="$T/nar" WT_NARRATION="$T/nar/narration.json" WT_PIPER_PYTHON="$T/piper" \
         WT_VOICES="$T/voices" node "$SKILL/scripts/build-narration.mjs" 2>&1)"
  RC=$?
  if [ "$RC" -eq 0 ]; then ok "build-narration completes with a stub voice"; else bad "build-narration completes with a stub voice" "rc=$RC: $OUT"; fi

  TJ="$T/nar/timing.json"
  if [ -f "$TJ" ]; then ok "timing.json is written"; else bad "timing.json is written" "missing"; fi

  rd() { node -e 'const t=require(process.argv[1]);const f=new Function("t","return "+process.argv[2]);console.log(String(f(t)));' "$TJ" "$1"; }

  # Each beat: 2s of speech + the 1.0s default pad = 3.0s total, offsets 0 and 3.
  eq "a beat's speech is MEASURED, not assumed"      "$(rd 't.sections[0].beats[0].speechSeconds')" "2"
  eq "…and its total adds the inter-beat pad"        "$(rd 't.sections[0].beats[0].totalSeconds')"  "3"
  eq "the first beat starts at 0"                    "$(rd 't.sections[0].beats[0].startSeconds')"  "0"
  eq "the second beat starts after the first's total" "$(rd 't.sections[0].beats[1].startSeconds')" "3"
  eq "a section's duration is the sum of its beats"  "$(rd 't.sections[0].durationSeconds')"        "6"
  eq "the total is the sum of the sections"          "$(rd 't.totalSeconds')"                       "9"
  eq "the pad is recorded so later stages can see it" "$(rd 't.padSeconds')"                        "1"
  # ⚠️ `beat.say ?? ""` — a beat with no text still gets a wav, so it still holds the frame
  # for its pad rather than vanishing from the timeline.
  eq "a beat with no text still gets a timed slot"   "$(rd 't.sections[1].beats[0].totalSeconds')"  "3"
  eq "a section with no title falls back to its id"  "$(rd 't.sections[1].title')"                  "outro"
  eq "the voice is recorded in the timing"           "$(rd 't.voice')"  "en_US-lessac-medium"
  eq "each beat carries its action through"          "$(rd 't.sections[0].beats[0].action.type')"   "goto"
  eq "a beat with no action gets an explicit none"   "$(rd 't.sections[1].beats[0].action.type')"   "none"

  # The pad is tunable, and the offsets must follow it.
  mkdir -p "$T/nar2"
  cp "$T/nar/narration.json" "$T/nar2/narration.json"
  WT_OUT="$T/nar2" WT_NARRATION="$T/nar2/narration.json" WT_PIPER_PYTHON="$T/piper" \
    WT_VOICES="$T/voices" WT_PAD_SECONDS=0.5 node "$SKILL/scripts/build-narration.mjs" >/dev/null 2>&1
  TJ="$T/nar2/timing.json"
  eq "WT_PAD_SECONDS changes the beat total"  "$(rd 't.sections[0].beats[0].totalSeconds')" "2.5"
  eq "…and the following beat's start"        "$(rd 't.sections[0].beats[1].startSeconds')" "2.5"
else
  echo
  echo "  ⚠️  ffmpeg absent — the build-narration pacing cases did NOT run."
fi

echo
echo "=== check-prereqs.sh — both directions ==="
# ⛔ THE SIGPIPE TRAP THE SCRIPT DOCUMENTS. `producer | grep -q` makes grep exit on the
# first hit, the producer takes SIGPIPE, and `pipefail` turns the pipeline non-zero — so a
# PRESENT tool reports as MISSING. The script captures first and matches after. The only
# way to prove that works is the POSITIVE direction: a real ffmpeg that HAS the filter must
# report ok. A suite that only checked the missing case would pass on the broken version.
# ⛔ THE STRUCTURAL GUARD, AND IT EXISTS BECAUSE THE BEHAVIOURAL ONE WAS A RACE. Whether
# SIGPIPE actually fires depends on whether the producer's output fits the 64 KiB pipe buffer
# before grep exits — so `ffmpeg -filters | grep -q` is a LATENT bug that happens to work on
# chatty builds. MEASURED 2026-10-05: a mutant restoring that pipeline was caught on the
# homelab Coder and SURVIVED on the GitHub runner. A behavioural test cannot reliably catch
# it; reading the source can, on every machine.
# ⚠️ So this asserts the SHAPE: the two probes must capture into a variable first and match
# afterwards. That is a lint, not a behaviour test, and it is the right instrument here —
# the defect is in the construct, not in any particular run of it.
PRQ="$(cat "$SKILL/scripts/check-prereqs.sh")"
if printf '%s' "$PRQ" | grep -Eq '(ffmpeg -hide_banner -filters|fc-list)[^|]*\| *grep'; then
  bad "captures the filter list before matching it" "a probe pipes straight into grep — SIGPIPE + pipefail will report a PRESENT tool as missing"
else
  ok "captures the filter list before matching it"
fi
if printf '%s' "$PRQ" | grep -Fq 'FILTERS="$(ffmpeg -hide_banner -filters'; then
  ok "…by assigning the filter list to a variable"
else
  bad "…by assigning the filter list to a variable" "the capture-then-match shape is gone"
fi

if [ "$HAVE_FF" -eq 1 ] && [ "$(ffmpeg -hide_banner -filters 2>/dev/null | grep -c ' subtitles ')" -gt 0 ]; then
  OUT="$(bash "$SKILL/scripts/check-prereqs.sh" 2>&1)"
  has "a PRESENT subtitles filter is reported ok" "$OUT" "ok  ffmpeg subtitles filter"
  has "…and a present ffmpeg is reported ok" "$OUT" "ok  ffmpeg"
else
  echo "  ⚠️  no ffmpeg with libass here — the positive direction did NOT run."
fi

# The negative direction, with an ffmpeg that reports no filters at all.
mkdir -p "$T/noass"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/noass/ffmpeg"
chmod +x "$T/noass/ffmpeg"
OUT="$(PATH="$T/noass:$PATH" bash "$SKILL/scripts/check-prereqs.sh" 2>&1)"
RC=$?
has "an ffmpeg without the subtitles filter is flagged" "$OUT" "ffmpeg has no subtitles filter"
has "…with the exact fix to apply" "$OUT" "--enable-libass"
fails "…and the script exits non-zero" "$RC"

# A completely bare PATH: every tool must be named, each with its own fix line.
# ⚠️ `$BASH` is the ABSOLUTE path of the running shell, and it is required here: with PATH
# emptied, `bash` itself is no longer resolvable, and the first version of this case failed
# eight assertions with "bash: command not found" — reporting a broken harness as eight
# defects in check-prereqs.sh.
mkdir -p "$T/bare"
OUT="$(PATH="$T/bare" "$BASH" "$SKILL/scripts/check-prereqs.sh" 2>&1 || true)"
for tool in node ffmpeg ffprobe sox python3; do
  has "a missing $tool is reported" "$OUT" "$tool missing"
done
has "a missing playwright is reported with its fix" "$OUT" "playwright-core missing"
has "a missing TTS venv is reported with its fix" "$OUT" "tts venv missing"
has "the summary says prerequisites are missing" "$OUT" "some prerequisites missing"

echo
printf 'asserted %s  failed %s\n' "$((PASS + FAIL))" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
