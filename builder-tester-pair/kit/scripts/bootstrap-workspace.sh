#!/usr/bin/env bash
# bootstrap-workspace.sh — OWNER runs this (needs sudo) after the workspace has been STOPPED and STARTED again.
#
# Closing terminals never stops the agents: they run in detached tmux sessions with a watchdog. What a workspace restart
# loses is everything outside your home and the shared disk: tmux, PyYAML, the extra Linux users (same-workspace testers)
# and the running processes. This puts them back, idempotently, and starts every agent of every pair.
#
#   sudo -v && bash bootstrap-workspace.sh [--dry-run]
#   PAIRS_DIR=/user/shared/pairs   (default; every <dir>/*/pair.yaml is one pair)
#
# It starts the agents with start-agent.sh (which does nothing for an agent that is already running).
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
PAIRS_DIR="${PAIRS_DIR:-/user/shared/pairs}"
OWNER="$(id -un)"
run() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
say() { printf '\n== %s\n' "$*"; }
PC() { python3 "$KIT/kit/lib/pairconf.py" "$@" 2>/dev/null; }

say "1/3 packages (lost when the workspace image restarts)"
for pkg in tmux python3-yaml ffmpeg; do      # ffmpeg: the df-video-intake skill (Slack video feedback)
  if dpkg -s "$pkg" >/dev/null 2>&1; then echo "ok   $pkg"; else echo "install $pkg"; run sudo apt-get install -y "$pkg" >/dev/null; fi
done
# whisper-cli lives on the shared disk (built once into /user/shared/tools); only the /usr/local/bin link is lost on a restart
TOOLS="${TOOLS_DIR:-/user/shared/tools}"
if [ -x "$TOOLS/whisper.cpp/build/bin/whisper-cli" ]; then
  [ -e /usr/local/bin/whisper-cli ] || { echo "link whisper-cli"; run sudo ln -sfn "$TOOLS/whisper.cpp/build/bin/whisper-cli" /usr/local/bin/whisper-cli; }
else echo "note: $TOOLS/whisper.cpp is not built — video feedback needs it (see docs/SETUP.md, Video feedback)"; fi

say "2/3 same-workspace tester users (if any pair uses them)"
if ls "$PAIRS_DIR"/*/pair.yaml >/dev/null 2>&1; then
  PAIR_CONFIGS="$(ls "$PAIRS_DIR"/*/pair.yaml | tr '\n' ' ')" run bash "$KIT/kit/scripts/tester-users.sh"
else echo "no pair.yaml under $PAIRS_DIR"; exit 1; fi

say "3/3 start every agent (detached; one that is already running is left alone)"
if [ "$DRY" = 1 ]; then bash "$KIT/kit/scripts/agents.sh" start --dry-run; else bash "$KIT/kit/scripts/agents.sh" start; fi
echo
bash "$KIT/kit/scripts/agents.sh" status
