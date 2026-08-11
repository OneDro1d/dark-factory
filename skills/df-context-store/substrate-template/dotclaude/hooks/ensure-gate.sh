#!/usr/bin/env sh
# ensure-gate.sh — self-arm the substrate staleness gate.
# Called from a SessionStart hook (.claude/settings.json) so the gate activates the
# first time any agent opens this repo — without anyone remembering to run a command.
# `core.hooksPath` is LOCAL git config (never committed), so the committed pre-commit
# file does NOT run on a fresh clone until this points git at it. Idempotent; safe to
# run every session. Non-destructive: never overrides an existing hooksPath or husky.
#
# Manual equivalent: git config core.hooksPath .claude/hooks
# Disable: SUBSTRATE_GATE=off (the pre-commit honors it) or unset core.hooksPath.

# Run from repo root (SessionStart cwd). Bail quietly if not a git repo or no gate.
[ -d ".git" ] || git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
[ -f ".claude/hooks/pre-commit" ] || exit 0

chmod +x .claude/hooks/pre-commit 2>/dev/null

current="$(git config --get core.hooksPath 2>/dev/null || true)"
if [ "$current" = ".claude/hooks" ]; then
  exit 0                                   # already armed
fi
if [ -n "$current" ]; then
  echo "[substrate] core.hooksPath='$current' already set; not overriding. Chain via .claude/hooks/pre-commit.local (see .claude/hooks/README.md)." >&2
  exit 0
fi
if [ -d ".husky" ]; then
  echo "[substrate] husky detected; not setting core.hooksPath. Chain via .claude/hooks/pre-commit.local (see .claude/hooks/README.md)." >&2
  exit 0
fi

git config core.hooksPath .claude/hooks && \
  echo "[substrate] staleness gate armed (core.hooksPath=.claude/hooks)." >&2
exit 0
