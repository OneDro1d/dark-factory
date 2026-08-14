#!/usr/bin/env bash
# Verify an existing install and print the exact fix for whatever is missing.
set -uo pipefail
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOICE="${WT_VOICE:-en_US-lessac-medium}"
FAIL=0
ok()   { printf '  ok  %s\n' "$1"; }
bad()  { printf '  !!  %s\n     fix: %s\n' "$1" "$2"; FAIL=1; }

for t in node ffmpeg ffprobe sox python3; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || bad "$t missing" "install $t"
done

[ -d "$SKILL/node_modules/playwright-core" ] \
  && ok "playwright-core" \
  || bad "playwright-core missing" "bash $SKILL/scripts/setup.sh"

# Playwright ships its own ffmpeg for recordVideo; the system one is not used.
if ls "$HOME/.cache/ms-playwright"/ffmpeg-* >/dev/null 2>&1 \
   || ls "${PLAYWRIGHT_BROWSERS_PATH:-/nonexistent}"/ffmpeg-* >/dev/null 2>&1; then
  ok "playwright ffmpeg (recordVideo)"
else
  bad "playwright ffmpeg missing — recordVideo will throw at newPage()" \
      "node $SKILL/node_modules/playwright-core/cli.js install ffmpeg"
fi

if [ -n "${CHROME_PATH:-}" ] && [ -x "${CHROME_PATH}" ]; then ok "chromium (CHROME_PATH)"
elif command -v chromium >/dev/null 2>&1; then ok "chromium (system)"
elif ls "$HOME/.cache/ms-playwright"/chromium* >/dev/null 2>&1; then ok "chromium (playwright)"
else bad "no chromium" "install one, or set CHROME_PATH"; fi

[ -x "$SKILL/.venv/bin/python" ] && ok "tts venv" || bad "tts venv missing" "bash $SKILL/scripts/setup.sh"
ls "$SKILL/.voices"/*"$VOICE"* >/dev/null 2>&1 \
  && ok "voice $VOICE" \
  || bad "voice $VOICE not downloaded" \
         "$SKILL/.venv/bin/python -m piper.download_voices $VOICE --data-dir $SKILL/.voices"

# NOTE: capture first, then match. `producer | grep -q` makes grep exit on the first hit,
# the producer takes SIGPIPE, and `set -o pipefail` turns the whole pipeline non-zero — so
# a present tool reports as missing. This bit both checks below.

# libass is what burns the captions in; an ffmpeg without it silently lacks the filter
FILTERS="$(ffmpeg -hide_banner -filters 2>/dev/null || true)"
case "$FILTERS" in
  *" subtitles "*) ok "ffmpeg subtitles filter (libass)" ;;
  *) bad "ffmpeg has no subtitles filter" "install an ffmpeg built with --enable-libass" ;;
esac

FONT="${WT_FONT:-DejaVu Sans}"
FONTS="$(fc-list 2>/dev/null || true)"
case "$FONTS" in
  *"$FONT"*) ok "caption font $FONT" ;;
  *) bad "caption font $FONT not found" "install it, or set WT_FONT to one you have" ;;
esac

echo
[ "$FAIL" = 0 ] && echo "all prerequisites present" || echo "some prerequisites missing (see fixes above)"
exit "$FAIL"
