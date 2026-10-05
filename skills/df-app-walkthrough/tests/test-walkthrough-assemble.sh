#!/usr/bin/env bash
# `scripts/assemble.mjs` — captions, the narration track, and the pre-roll trim.
#
# Three properties are worth a test here and all three are silent when they break:
#
#  1. ⛔ CAPTION ESCAPING. `narration.json` is DATA, and ASS treats `{…}` as an override
#     block — a caption containing braces stops being text and becomes positioning or
#     styling instructions. `esc()` strips them. Nothing downstream would complain; the
#     captions would simply render wrong, or not at all.
#  2. ⛔ THE AUDIO OFFSETS. Each beat's wav is front-padded by the gap between the previous
#     beat's speech ENDING and this beat's MEASURED start. Get it wrong and the narration
#     drifts out of sync with the video — progressively, so the start of the video looks
#     fine and nobody notices until the end.
#  3. ⛔ THE PRE-ROLL TRIM. `recordVideo` starts at browser-context creation, which is
#     BEFORE sign-in. `videoPrefixSeconds` is how the login is cut out. A regression here
#     publishes a video of somebody signing in.
#
# ⚠️ sox AND THE FINAL ffmpeg ARE STUBBED, AND THE STUBS RECORD THEIR ARGUMENTS. That is
# the point rather than a limitation: what is under test is the OFFSETS assemble.mjs
# computes and the arguments it builds, not sox's ability to pad a wav. Where a real file
# has to be readable (ffprobe is called on the raw video, the narration and the final mp4)
# the stubs hand over a genuine one made with real ffmpeg, so no probe is faked.
#
# ⚠️ WHAT IS NOT COVERED: that libass actually burns the captions in, and that the mux
# produces a playable file. Both need a real encode of a real recording. `check-prereqs.sh`
# checks the libass filter is present, and `verify.mjs` checks the artefact afterwards.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
A="$SKILL/scripts/assemble.mjs"

command -v node >/dev/null 2>&1 || { echo "test-walkthrough-assemble: need node"; exit 1; }
[ -f "$A" ] || { echo "test-walkthrough-assemble: no assemble.mjs at $A"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wtasm.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
# ⚠️ `--` is load-bearing in both. Most of the strings asserted below are ffmpeg arguments
# beginning with a dash (`-ss 7.25`, `-map [v]`, `-movflags +faststart`), and without the
# terminator grep reads them as its OWN options: `-ss` became "invalid option" and `-map`
# became "invalid max count", and each one rendered as a failing assertion about assemble.mjs
# rather than a broken helper. A test harness misreporting its own breakage as a defect in
# the subject is the worst failure a suite can have, so it is called out here.
has() { if printf '%s' "$2" | grep -Fq -- "$3"; then ok "$1"; else bad "$1" "[$2] does not contain [$3]"; fi; }
hasnt() { if printf '%s' "$2" | grep -Fq -- "$3"; then bad "$1" "[$2] still contains [$3]"; else ok "$1"; fi; }

echo "=== assemble.mjs — the guard ==="
# No recorded-timeline.json: a clear refusal naming the next step, not a stack trace.
mkdir -p "$T/noguard"
OUT="$(WT_OUT="$T/noguard" node "$A" 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then ok "assemble refuses with no recorded-timeline.json"; else bad "assemble refuses with no recorded-timeline.json" "rc=0"; fi
has "…and says which script to run first" "$OUT" "run record-walkthrough.mjs first"

HAVE_FF=0
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then HAVE_FF=1; fi
if [ "$HAVE_FF" -eq 0 ]; then
  echo
  echo "  ⚠️  ffmpeg/ffprobe absent — the caption and offset cases below did NOT run."
  printf '\nCOVERAGE: the guard only (ffmpeg absent)\n'
  printf 'asserted %s  failed %s\n' "$((PASS + FAIL))" "$FAIL"
  printf 'ASSERTIONS: %s\n' "$((PASS + FAIL))"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

# ---------------------------------------------------------------- real media + stubs
# Genuine files, so every ffprobe assemble.mjs runs is a real measurement.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=f=440:d=2" "$T/real-2s.wav"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=f=440:d=3" "$T/real-3s.wav"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=s=160x120:d=20" \
  -c:v libx264 -pix_fmt yuv420p "$T/raw-video.mp4"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=f=440:d=10" "$T/real-10s.wav"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=s=160x120:d=10" \
  -f lavfi -i "sine=f=440:d=10" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$T/real-final.mp4"

mkdir -p "$T/bin"
LOG="$T/calls.log"
: > "$LOG"

# sox stub: records the padding gaps and the concat, and produces a REAL wav so the
# ffprobe of the narration track measures something rather than nothing.
{
  printf '#!/usr/bin/env bash\n'
  printf 'LOG=%s\n' "$LOG"
  printf 'REAL=%s\n' "$T/real-10s.wav"
  printf 'if [ "$3" = "pad" ]; then\n'
  printf '  echo "PAD in=$1 out=$2 gap=$4" >> "$LOG"\n'
  printf '  cp "$REAL" "$2"\n'
  printf 'else\n'
  printf '  echo "CONCAT $*" >> "$LOG"\n'
  printf '  eval "last=\\${$#}"\n'
  printf '  cp "$REAL" "$last"\n'
  printf 'fi\n'
} > "$T/bin/sox"

# ffmpeg stub: records the burn/mux argv and produces a REAL mp4 for the final probe.
# ⚠️ It must NOT exec the real ffmpeg — a genuine encode here would make the suite slow
# and would test libx264, not assemble.mjs.
{
  printf '#!/usr/bin/env bash\n'
  printf 'LOG=%s\n' "$LOG"
  printf 'REAL=%s\n' "$T/real-final.mp4"
  printf 'echo "FFMPEG $*" >> "$LOG"\n'
  printf 'eval "last=\\${$#}"\n'
  printf 'cp "$REAL" "$last"\n'
} > "$T/bin/ffmpeg"
chmod +x "$T/bin/sox" "$T/bin/ffmpeg"
ln -sf "$(command -v ffprobe)" "$T/bin/ffprobe"

# ---------------------------------------------------------------- the fixture
# Three beats, deliberately OUT OF ORDER in the file, with known wav durations (2s, 3s, 2s)
# and measured starts that leave a 1s gap, then a 0s gap, then a 4s gap.
D="$T/run"
mkdir -p "$D"
cat > "$D/recorded-timeline.json" <<JSON
{
  "width": 1280,
  "height": 720,
  "videoPath": "$T/raw-video.mp4",
  "videoPrefixSeconds": 7.25,
  "problems": [],
  "sections": [
    {
      "id": "s2",
      "beats": [
        { "startSeconds": 6, "endSeconds": 8, "caption": "third {\\\\pos(0,0)} beat", "wav": "$T/real-2s.wav" }
      ]
    },
    {
      "id": "s1",
      "beats": [
        { "startSeconds": 1, "endSeconds": 3, "caption": "first\\nline two", "wav": "$T/real-2s.wav" },
        { "startSeconds": 3, "endSeconds": 6, "caption": "", "wav": "$T/real-3s.wav" }
      ]
    }
  ]
}
JSON

OUT="$(PATH="$T/bin:$PATH" WT_OUT="$D" node "$A" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then ok "assemble completes on a well-formed timeline"; else bad "assemble completes on a well-formed timeline" "rc=$RC: $OUT"; fi

ASS="$D/captions.ass"
[ -f "$ASS" ] || { bad "captions.ass is written" "missing"; printf 'ASSERTIONS: %s\n' "$((PASS + FAIL))"; exit 1; }
ok "captions.ass is written"

echo
echo "=== assemble.mjs — captions ==="

# Only beats WITH a caption become cues: the empty one must not produce a blank band.
CUES="$(grep -c '^Dialogue:' "$ASS")"
eq "a beat with an empty caption produces no cue" "$CUES" "2"
has "…and the cue count is reported" "$OUT" "captions: 2 cues"

# ⛔ BRACE STRIPPING. `{\pos(0,0)}` is an ASS override block. Left in, the caption stops
# being text; stripped, it renders as literal characters.
hasnt "ASS override braces are stripped from captions" "$(cat "$ASS")" "{"
has "…leaving the inner text as plain characters" "$(cat "$ASS")" "pos(0,0)"

# Newlines become ASS line breaks, not literal newlines that would split the Dialogue line.
has "a newline in a caption becomes an ASS line break" "$(cat "$ASS")" 'first\Nline two'

# ⛔ BEATS ARE SORTED BY MEASURED START, ACROSS SECTIONS. The fixture lists s2 before s1 on
# purpose: cues emitted in file order would caption the wrong moments.
FIRSTCUE="$(grep '^Dialogue:' "$ASS" | head -1)"
has "cues are ordered by measured start, not file order" "$FIRSTCUE" 'first\Nline two'

# The ASS clock is h:mm:ss.cc. 1s and 6s both exercise it; a bad formatter usually shows up
# as a missing pad or a wrong minute rollover.
has "cue start is formatted as h:mm:ss.cc" "$FIRSTCUE" "0:00:01.00"
has "cue end is formatted as h:mm:ss.cc" "$FIRSTCUE" "0:00:03.00"
LASTCUE="$(grep '^Dialogue:' "$ASS" | tail -1)"
has "a later cue carries its own measured window" "$LASTCUE" "0:00:06.00"

# The canvas must match the recording, or libass scales the captions wrongly.
has "PlayResX comes from the recorded width" "$(cat "$ASS")" "PlayResX: 1280"
has "PlayResY comes from the recorded height" "$(cat "$ASS")" "PlayResY: 720"

echo
echo "=== assemble.mjs — narration offsets ==="
# ⛔ THE SYNC MATH. cursor starts at 0. Beat 1 starts at 1s -> pad 1.000. Its wav is 2s, so
# cursor becomes 3. Beat 2 starts at 3s -> pad 0.000. Its wav is 3s, cursor becomes 6.
# Beat 3 starts at 6s -> pad 0.000. Every gap here is derived from a REAL ffprobe of a real
# wav, so this asserts the arithmetic and the measurement together.
PADS="$(grep '^PAD' "$LOG" | sed 's/.*gap=//' | tr '\n' ' ')"
eq "each beat is front-padded by its measured gap" "$PADS" "1.000 0.000 0.000 "
PADCOUNT="$(grep -c '^PAD' "$LOG")"
eq "every beat is padded, including the uncaptioned one" "$PADCOUNT" "3"
if grep -q '^CONCAT' "$LOG"; then ok "the padded parts are concatenated into one track"; else bad "the padded parts are concatenated into one track" "no CONCAT in log"; fi
has "…into narration.wav" "$(grep '^CONCAT' "$LOG")" "narration.wav"

echo
echo "=== assemble.mjs — the pre-roll trim ==="
# ⛔ THE LOGIN MUST NOT BE IN THE VIDEO. `-ss <prefix>` before `-i` is what cuts it.
BURN="$(grep '^FFMPEG' "$LOG" | tail -1)"
has "the mux seeks past the pre-roll" "$BURN" "-ss 7.25"
# 7.25 -> "7.3": toFixed(1) rounds half away from zero. Asserting "7.2" here was my own
# error, caught by this suite on its first run.
has "…and reports how much it trimmed" "$OUT" "trimming 7.3s of pre-roll"
has "the captions are burned in with libass" "$BURN" "subtitles="
has "…mapping the burned video and the narration audio" "$BURN" "-map [v] -map 1:a"
has "the output is faststart mp4" "$BURN" "-movflags +faststart"
if [ -f "$D/walkthrough.mp4" ]; then ok "the final mp4 lands at the expected path"; else bad "the final mp4 lands at the expected path" "missing"; fi
if [ -d "$D/tmp-audio" ]; then bad "the scratch audio directory is cleaned up" "tmp-audio still present"; else ok "the scratch audio directory is cleaned up"; fi

echo
printf 'COVERAGE: guard + captions + offsets + trim; the real encode is not covered (see header)\n'
printf 'asserted %s  failed %s\n' "$((PASS + FAIL))" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
