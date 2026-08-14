#!/usr/bin/env bash
# One-shot install of the local toolchain, into the skill directory.
# Everything runs locally: no recording service, no upload, no API key.
set -euo pipefail

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOICE="${WT_VOICE:-en_US-lessac-medium}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "MISSING: $1 — $2"
    exit 1
  }
}

echo "== checking system tools"
need node   "install Node >= 18"
need ffmpeg "apt install ffmpeg  |  brew install ffmpeg"
need ffprobe "ships with ffmpeg"
need sox    "apt install sox  |  brew install sox"
need python3 "install Python 3 with venv"
echo "   ok"

echo "== playwright-core"
cd "$SKILL"
[ -f package.json ] || cat > package.json <<'JSON'
{ "name": "df-app-walkthrough", "private": true, "type": "module",
  "dependencies": { "playwright-core": "^1.55.0" } }
JSON
npm install --no-audit --no-fund >/dev/null
echo "   ok"

# Playwright does NOT encode video with your system ffmpeg — it pipes screencast frames to
# its own pinned build. Without this, recordVideo throws at newPage().
echo "== playwright's bundled ffmpeg (required for recordVideo)"
node "$SKILL/node_modules/playwright-core/cli.js" install ffmpeg >/dev/null
echo "   ok"

echo "== a chromium to record"
if [ -n "${CHROME_PATH:-}" ] && [ -x "${CHROME_PATH}" ]; then
  echo "   using CHROME_PATH=$CHROME_PATH"
elif command -v chromium >/dev/null 2>&1; then
  echo "   using system chromium ($(command -v chromium))"
elif command -v chromium-browser >/dev/null 2>&1; then
  echo "   using system chromium-browser — export CHROME_PATH=$(command -v chromium-browser)"
else
  echo "   no system chromium; fetching Playwright's"
  node "$SKILL/node_modules/playwright-core/cli.js" install chromium >/dev/null
  echo "   fetched — set CHROME_PATH to it, or install a system chromium"
fi

echo "== text-to-speech (piper, offline)"
[ -d "$SKILL/.venv" ] || python3 -m venv "$SKILL/.venv"
"$SKILL/.venv/bin/pip" install --quiet --upgrade pip >/dev/null
"$SKILL/.venv/bin/pip" install --quiet piper-tts >/dev/null
# The voice model is NOT fetched by `-m <voice>`; without this you get "Unable to find voice".
"$SKILL/.venv/bin/python" -m piper.download_voices "$VOICE" --data-dir "$SKILL/.voices" >/dev/null 2>&1
echo "   ok ($VOICE)"

echo
echo "setup complete. Verify with:  bash $SKILL/scripts/check-prereqs.sh"
