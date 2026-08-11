#!/usr/bin/env bash
# df-video-intake — decompose a video into a transcript + timestamped frames
# so Claude (which cannot read video/audio natively) can consume it.
#
# Usage:
#   extract-video.sh <video> [interval_seconds] [whisper_model]
#     video            path to .mp4/.mov/.webm/etc (quote if it has spaces)
#     interval_seconds frame sampling interval (default 12)
#     whisper_model    base.en | small.en | medium.en (default small.en)
#
# Output: <video-dir>/<video-basename>-extract/
#   probe.txt, audio.wav, transcript.txt, transcript.srt, frames/iv_NNNN.jpg
#
# Env: WHISPER_MODEL_DIR overrides the model cache (default ~/.cache/whisper-cpp)
set -euo pipefail

VIDEO="${1:?Usage: extract-video.sh <video> [interval_seconds=12] [model=small.en]}"
INTERVAL="${2:-12}"
MODEL="${3:-small.en}"

[[ -f "$VIDEO" ]] || { echo "ERROR: file not found: $VIDEO" >&2; exit 1; }

# --- tool checks (fail early with install hints) ---
command -v ffmpeg  >/dev/null || { echo "ERROR: ffmpeg missing.  macOS: brew install ffmpeg  |  Debian/Ubuntu: sudo apt install ffmpeg" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "ERROR: ffprobe missing (ships with ffmpeg)" >&2; exit 1; }
WHISPER=""
for c in whisper-cli whisper-cpp main; do
  if command -v "$c" >/dev/null 2>&1; then WHISPER="$c"; break; fi
done
[[ -n "$WHISPER" ]] || { echo "ERROR: whisper-cpp missing.  macOS: brew install whisper-cpp" >&2; exit 1; }

# --- paths ---
DIR="$(cd "$(dirname "$VIDEO")" && pwd)"
BASE="$(basename "${VIDEO%.*}")"
OUT="$DIR/${BASE}-extract"
FRAMES="$OUT/frames"
mkdir -p "$FRAMES"

# --- model cache (downloaded once, reused across runs) ---
CACHE="${WHISPER_MODEL_DIR:-$HOME/.cache/whisper-cpp}"
mkdir -p "$CACHE"
MODELFILE="$CACHE/ggml-${MODEL}.bin"
if [[ ! -f "$MODELFILE" ]]; then
  echo "Downloading whisper model ggml-${MODEL}.bin -> $CACHE ..."
  curl -fL -o "$MODELFILE" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL}.bin"
fi

# --- probe ---
ffprobe -v error \
  -show_entries format=duration,size:stream=codec_type,codec_name,width,height,r_frame_rate,sample_rate,channels \
  -of default=noprint_wrappers=1 "$VIDEO" > "$OUT/probe.txt" 2>&1 || true

HAS_AUDIO="$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$VIDEO" 2>/dev/null || true)"

# --- audio + transcript ---
if [[ -n "$HAS_AUDIO" ]]; then
  echo "Extracting audio -> 16kHz mono wav ..."
  ffmpeg -y -i "$VIDEO" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$OUT/audio.wav" >/dev/null 2>&1
  echo "Transcribing with $WHISPER ($MODEL) ... (output: transcript.txt + .srt)"
  "$WHISPER" -m "$MODELFILE" -f "$OUT/audio.wav" -otxt -osrt -of "$OUT/transcript" -t 8 > "$OUT/whisper.log" 2>&1
else
  echo "No audio stream detected; skipping transcription."
fi

# --- frames (fixed interval: scene-detect fails on screen recordings — UI changes gradually) ---
echo "Extracting frames every ${INTERVAL}s ..."
ffmpeg -y -i "$VIDEO" -vf "fps=1/${INTERVAL}" -q:v 3 "$FRAMES/iv_%04d.jpg" >/dev/null 2>&1
COUNT="$(find "$FRAMES" -name 'iv_*.jpg' | wc -l | tr -d ' ')"

# --- summary ---
echo ""
echo "=== df-video-intake complete ==="
echo "Output dir : $OUT"
if [[ -n "$HAS_AUDIO" ]]; then echo "Transcript : $OUT/transcript.txt  (+ transcript.srt = timestamped)"; fi
echo "Frames     : $COUNT @ ${INTERVAL}s  ->  $FRAMES/iv_NNNN.jpg"
echo "Frame time : iv_NNNN  ≈  (NNNN-1) * ${INTERVAL}s into the video"
echo "Next       : Read transcript.txt fully (cheap); Read frames selectively, guided by .srt timestamps."
