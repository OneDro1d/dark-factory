#!/usr/bin/env bash
# `scripts/verify.mjs` — the stage that decides whether a finished recording is shippable.
#
# ⛔ THE DEFECT THIS SUITE EXISTS FOR, AND WHY IT IS THE SAME ONE TWICE. Before #224 the
# black-frame probe scored "the filter never ran" identically to "the filter ran and found
# nothing": no `black_start:` matches either way, `black.length === 0`, printed
# `ok no black stretch`, exit 0. An all-black twelve-second video was ACCEPTED by the check
# written to catch exactly that. The repair was to read the probe's exit status, and the
# same reasoning applies to the loudness probe sitting next to it — so both are tested here
# in both directions: the probe fires, the probe stays quiet, and the probe cannot run.
#
# ⛔ AN ABSENCE IS ONLY EVIDENCE WHEN THE THING THAT WOULD HAVE REPORTED A PRESENCE IS KNOWN
# TO HAVE RUN. That is the whole content of this file.
#
# ⚠️ sox IS STUBBED FOR EVERY CASE, AND THAT IS NOT CONVENIENCE. sox is absent on plenty of
# machines (including the Coder this was written on). Without a stub, verify.mjs's RMS check
# fails for a reason unrelated to the case under test and EVERY run exits 1 — during the
# #224 review that nearly got attributed to the black-frame defect. Isolate the variable,
# then measure. The RMS branch gets its own case, with a stub that reports silence.
#
# ⚠️ WHAT THIS SUITE CANNOT DO WITHOUT ffmpeg is stated, counted and printed rather than
# skipped silently — see the COVERAGE line at the end.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$(cd "$HERE/.." && pwd)/scripts/verify.mjs"

command -v node >/dev/null 2>&1 || { echo "test-walkthrough-verify: need node"; exit 1; }
[ -f "$V" ] || { echo "test-walkthrough-verify: no verify.mjs at $V"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wtverify.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
SKIPPED=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

HAVE_FF=0
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then HAVE_FF=1; fi
REAL_FFMPEG="$(command -v ffmpeg || true)"

# ---------------------------------------------------------------- stubs
mkdir -p "$T/bin"
# sox reporting healthy speech, so the audio floor never decides a case that is not about it
printf '#!/usr/bin/env bash\ncat > /dev/null\necho "RMS     amplitude:     0.250000"\n' > "$T/bin/sox"
# sox reporting silence, for the one case that IS about the floor
mkdir -p "$T/bin-silent"
printf '#!/usr/bin/env bash\ncat > /dev/null\necho "RMS     amplitude:     0.000100"\n' > "$T/bin-silent/sox"
# ⛔ sox ABSENT ENTIRELY, AND THIS ONE MUST BE HERMETIC. The first version prepended the stub
# dir to the INHERITED PATH, so "sox is missing" was true only because this machine happens
# not to have sox — the assertion measured the machine, not verify.mjs, and would have failed
# on any developer box with sox installed. run-tests.sh's own header warns about exactly this
# shape: a suite whose subject depends on what the environment happens to provide is not
# hermetic anywhere, it merely fails visibly on the machines that differ.
#
# So this dir holds symlinks to everything verify.mjs needs AND NOTHING ELSE, and the case runs
# with PATH set to exactly this dir. `sh` is in the list because verify.mjs shells out to
# `sh -c 'ffmpeg … | sox …'` for the RMS probe.
mkdir -p "$T/bin-nosox"
chmod +x "$T/bin/sox" "$T/bin-silent/sox"
# ⚠️ `bash` is in this list and it is not decoration: the stub sox starts
# `#!/usr/bin/env bash`, and with PATH scoped to one directory `env` cannot find bash, so the
# stub silently fails to execute. The mirror case below failed for exactly that reason before
# bash was added — a missing interpreter looks identical to "sox reported nothing".
for tool in node sh bash ffmpeg ffprobe; do
  src="$(command -v "$tool" || true)"
  [ -n "$src" ] && ln -sf "$src" "$T/bin-nosox/$tool"
done

# An ffmpeg that is REAL except for one named filter. Scoping the breakage to a single
# filter is what makes the "probe could not run" cases honest: a stub that broke every
# ffmpeg call would crash elsewhere and prove nothing about the branch under test.
mk_broken_ffmpeg() { # mk_broken_ffmpeg <dir> <filter-name>
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for arg in "$@"; do\n'
    printf '  case "$arg" in *%s*) echo "Unknown filter '"'"'%s'"'"'" >&2; exit 1 ;; esac\n' "$2" "$2"
    printf 'done\n'
    printf 'exec %s "$@"\n' "$REAL_FFMPEG"
  } > "$1/ffmpeg"
  chmod +x "$1/ffmpeg"
  cp "$T/bin/sox" "$1/sox"
  # ffprobe must stay reachable: the stub dir goes on the FRONT of PATH, and verify.mjs
  # calls ffprobe as well as ffmpeg. An unconditional link, because a trailing `&&` here
  # would also make this function's exit status depend on the test.
  ln -sf "$(command -v ffprobe)" "$1/ffprobe"
}

# ---------------------------------------------------------------- fixtures
# mkfix <name> <video-lavfi> <audio-lavfi> [extra ffmpeg args...]
mkfix() {
  local name="$1" vsrc="$2" asrc="$3"; shift 3
  local d="$T/$name"
  mkdir -p "$d"
  ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i "$vsrc" -f lavfi -i "$asrc" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$@" "$d/walkthrough.mp4" 2>/dev/null
  printf 'Dialogue: 0,0:00:01.00,0:00:05.00,Cap,,0,0,0,,one\n' > "$d/captions.ass"
  printf '{"sections":[{"id":"s1","startSeconds":1,"endSeconds":5}],"problems":[]}\n' > "$d/recorded-timeline.json"
}

# vrun <fixture> <stub-dir> -> sets OUT and RC. Stub dir goes in FRONT of the inherited PATH.
vrun() {
  OUT="$(PATH="$2:$PATH" WT_OUT="$T/$1" node "$V" 2>&1)"
  RC=$?
}

# vrun_exact <fixture> <dir> -> same, but PATH is EXACTLY <dir>: nothing is inherited, so what
# the machine happens to have installed cannot change the result.
vrun_exact() {
  OUT="$(PATH="$2" WT_OUT="$T/$1" node "$V" 2>&1)"
  RC=$?
}

# Assert verify.mjs put a line matching <re> on the ok side / the ATTENTION side.
said_ok()  { if printf '%s\n' "$OUT" | grep -Eq "^  ok  .*$1"; then ok "$2"; else bad "$2" "no 'ok' line matching /$1/"; fi; }
said_bad() { if printf '%s\n' "$OUT" | grep -Eq "^  !!  .*$1"; then ok "$2"; else bad "$2" "no '!!' line matching /$1/"; fi; }

echo "=== verify.mjs — refusals that need no ffmpeg ==="

# A missing artefact must be named, not inferred. This case runs everywhere, so the suite
# can never be vacuous even on a machine with no ffmpeg at all.
mkdir -p "$T/empty"
vrun empty "$T/bin"
if [ "$RC" -ne 0 ]; then ok "a missing mp4 exits non-zero"; else bad "a missing mp4 exits non-zero" "rc=$RC"; fi
if printf '%s\n' "$OUT" | grep -q "FAIL: no mp4 at"; then
  ok "…and names the path it looked for"
else
  bad "…and names the path it looked for" "output was: $OUT"
fi

if [ "$HAVE_FF" -eq 0 ] && [ -n "${WT_TESTS_REQUIRE_FULL:-}" ]; then
  echo
  echo "REFUSING TO DEGRADE: WT_TESTS_REQUIRE_FULL is set and ffmpeg/ffprobe is absent."
  echo "  11 of 13 cases would not run — including every black-frame and loudness probe case."
  echo "  Install ffmpeg, or unset WT_TESTS_REQUIRE_FULL to accept reduced coverage knowingly."
  printf 'ASSERTIONS: %s\n' "$((PASS + FAIL))"
  exit 1
fi

if [ "$HAVE_FF" -eq 0 ]; then
  SKIPPED=11
  echo
  echo "  ⚠️  ffmpeg/ffprobe absent — the 11 artefact cases below did NOT run."
  echo "      They are the ones that test the probes; this run proves only the guard above."
  printf '\nCOVERAGE: 2 of 13 cases ran (ffmpeg absent)\n'
  printf 'asserted %s  failed %s\n' "$((PASS + FAIL))" "$FAIL"
  printf 'ASSERTIONS: %s\n' "$((PASS + FAIL))"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

mkfix black   "color=c=black:s=320x240:d=12"      "sine=f=440:d=12"
mkfix moving  "testsrc=s=320x240:d=12"            "sine=f=440:d=12"
mkfix short   "testsrc=s=320x240:d=5"             "sine=f=440:d=5"
mkfix silent  "testsrc=s=320x240:d=12"            "anullsrc=r=44100:cl=mono:d=12"
mkfix loud    "testsrc=s=320x240:d=12"            "sine=f=440:d=12" -filter:a "volume=20"
mkdir -p "$T/noaudio"
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i "testsrc=s=320x240:d=12" \
  -c:v libx264 -pix_fmt yuv420p -an "$T/noaudio/walkthrough.mp4" 2>/dev/null
printf 'Dialogue: 0,0:00:01.00,0:00:05.00,Cap,,0,0,0,,one\n' > "$T/noaudio/captions.ass"
printf '{"sections":[{"id":"s1","startSeconds":1,"endSeconds":5}],"problems":[]}\n' > "$T/noaudio/recorded-timeline.json"

mk_broken_ffmpeg "$T/no-blackdetect" blackdetect
mk_broken_ffmpeg "$T/no-ebur128"     ebur128

echo
echo "=== verify.mjs — the black-frame probe, all three ways ==="

# 1. POSITIVE CONTROL. Without this the other two prove nothing: a probe that can never
#    fire would also report "no black stretch" on a good video.
vrun black "$T/bin"
said_bad 'black for 1s or more at' "an all-black video is REJECTED"

# 2. NEGATIVE CONTROL.
vrun moving "$T/bin"
said_ok 'no black stretch' "a moving video passes the black check"

# 3. ⛔ THE #224 DEFECT. A probe that cannot run must produce NO VERDICT, not a clean one.
vrun black "$T/no-blackdetect"
said_bad 'black detection did not run' "an unrunnable black probe REFUSES to give a verdict"
if [ "$RC" -ne 0 ]; then
  ok "…and the run exits non-zero"
else
  bad "…and the run exits non-zero" "rc=$RC — this is the #224 defect, back"
fi

echo
echo "=== verify.mjs — the loudness probe, the same three ways ==="
# The branch next door, and the reason #224's fix was written as `ran` rather than a
# special case: an absence from ebur128 is just as uninformative as one from blackdetect.
vrun moving "$T/bin"
said_ok 'loudness -?[0-9.]+ LUFS' "loudness is MEASURED on a normal file"
said_ok 'true peak -?[0-9.]+ dBTP' "true peak is measured on a normal file"

vrun moving "$T/no-ebur128"
said_bad 'loudness could not be measured' "an unrunnable loudness probe REFUSES a verdict"
said_bad 'true peak could not be measured' "…and so does the true-peak arm"

vrun loud "$T/bin"
# ⚠️ The regex demands a MEASURED number. A bare /true peak/ would also be satisfied by
# "true peak could not be measured", so the assertion would pass on a broken probe — the
# same could-not-fail shape this whole file is about, smuggled in through a loose pattern.
said_bad 'true peak -?[0-9.]+ dBTP' "a clipping file is REJECTED on a MEASURED true peak"

echo
echo "=== verify.mjs — the remaining artefact checks ==="

vrun silent "$T/bin-silent"
said_bad 'audio RMS' "a silent track is REJECTED on the RMS floor"

# sox absent is a real deployment condition, not a contrivance: it is absent on the machine this
# suite was written on, and on the GitHub runner. The floor must fail, and the run must not crash.
vrun_exact moving "$T/bin-nosox"
said_bad 'audio RMS 0\.0000' "a MISSING sox fails the floor rather than crashing"

# ⛔ THE PAIR IS THE CONTROL, and it is what makes the case above mean anything. Same fixture,
# same verify.mjs, differing in ONE thing — whether sox is reachable — and giving OPPOSITE
# verdicts. On its own the case above would pass identically on a box where sox is installed
# and the scoping is broken, which is the state it was in when first written: it would have
# been measuring this machine's lack of sox. The mirror below also proves the stub sox works,
# so the failure above is attributable to absence rather than to a broken stub.
mkdir -p "$T/bin-haxsox"
cp "$T/bin/sox" "$T/bin-haxsox/sox"
for tool in node sh bash ffmpeg ffprobe; do
  [ -e "$T/bin-nosox/$tool" ] && cp -P "$T/bin-nosox/$tool" "$T/bin-haxsox/$tool"
done
vrun_exact moving "$T/bin-haxsox"
said_ok 'audio RMS 0\.2500' "…and the SAME fixture passes the floor when sox IS reachable"

vrun short "$T/bin"
said_bad 'duration' "a too-short recording is REJECTED"

vrun noaudio "$T/bin"
said_bad 'no audio stream' "a video with no audio track is REJECTED"

# Captions: a recording nobody can read the narration of is not shippable.
cp -R "$T/moving" "$T/nocaps"
rm -f "$T/nocaps/captions.ass"
vrun nocaps "$T/bin"
said_bad '0 caption cues' "a recording with no caption cues is REJECTED"

# A section whose midpoint lies beyond the video cannot be sampled, and a frame count
# short of the section count must fail rather than reporting the frames it did get.
cp -R "$T/moving" "$T/offend"
printf '{"sections":[{"id":"s1","startSeconds":1,"endSeconds":5},{"id":"s2","startSeconds":600,"endSeconds":620}],"problems":[]}\n' \
  > "$T/offend/recorded-timeline.json"
vrun offend "$T/bin"
said_bad '1/2 section frames' "a section the video does not reach is REJECTED, not quietly dropped"

# Recorder problems are failures. A beat that threw mid-recording is the single most
# common reason a well-formed file is still wrong.
cp -R "$T/moving" "$T/probs"
printf '{"sections":[{"id":"s1","startSeconds":1,"endSeconds":5}],"problems":["s1[0] click: no visible match"]}\n' \
  > "$T/probs/recorded-timeline.json"
vrun probs "$T/bin"
said_bad '1 recorder problems' "a recorder problem is REJECTED"

# And the whole-artefact control: a good recording must PASS. Without it every assertion
# above could be satisfied by a verify.mjs that rejects everything.
vrun moving "$T/bin"
if [ "$RC" -eq 0 ]; then
  ok "a GOOD recording passes end to end (exit 0)"
else
  bad "a GOOD recording passes end to end (exit 0)" "rc=$RC: $(printf '%s\n' "$OUT" | grep '!!' | head -3)"
fi
if [ -f "$T/moving/verify/s1.png" ]; then
  ok "…and a frame is extracted per section for a human to LOOK at"
else
  bad "…and a frame is extracted per section" "no verify/s1.png"
fi

echo
printf 'COVERAGE: all 13 cases ran (ffmpeg present); skipped %s\n' "$SKIPPED"
printf 'asserted %s  failed %s\n' "$((PASS + FAIL))" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
