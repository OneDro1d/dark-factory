#!/usr/bin/env bash
# register-merge-drivers.sh — register the git merge drivers a notepad needs, at USER scope.
#
# ⛔ WHY THIS IS A BOOT-KIT SCRIPT AND NOT A LINE IN AN INSTALLER.
# The registration first shipped inside `skills/agent-notepad/plugin/install.sh` (T1 #107).
# Measured hours later: NOTHING ON THIS FLEET RUNS THAT INSTALLER. A Tier-3 instance installer
# copies hook files by declaration and invokes T1 engine scripts from its vendored pin — it
# never executes the plugin's own installer. So the driver was DECLARED, INSTALLED AND NEVER
# INVOKED on both machines it was built for: this estate's signature defect, committed by the
# fix for a different instance of the same defect.
#
# `wire-settings.py` (#84) had already solved exactly this and shows the shape: put the
# MECHANISM in boot-kit/scripts, and let every installer invoke it from the pinned engine. A
# kit then inherits it by MOVING A PIN, not by someone remembering to edit an installer per
# machine. This file is that shape, and it is the ONE home for the registration — the plugin
# installer now calls it rather than carrying a second copy.
#
# ⚠️ FAIL-SAFE BY CONSTRUCTION. Without any registration git falls back to an ordinary
# conflict — today's behaviour — never to corruption. This is a convenience, so every failure
# path here WARNS and exits 0. It must never be able to fail an install.
#
# Usage: register-merge-drivers.sh [--lib-dir <DIR>] [--home <DIR>] [--dry-run]
#   --lib-dir  where merge-session-index.py lives
#              (default: <HOME>/.claude/hooks/agent-notepad/lib)
#   --home     the target HOME (default: $HOME)
set -uo pipefail

TARGET_HOME="${HOME:-}"
LIB_DIR=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lib-dir) LIB_DIR="${2:?--lib-dir needs a directory}"; shift 2 ;;
    --lib-dir=*) LIB_DIR="${1#*=}"; shift ;;
    --home) TARGET_HOME="${2:?--home needs a directory}"; shift 2 ;;
    --home=*) TARGET_HOME="${1#*=}"; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '1,26p' "$0"; exit 0 ;;
    *) echo "register-merge-drivers: unknown argument: $1" >&2; exit 0 ;;
  esac
done
[ -n "$LIB_DIR" ] || LIB_DIR="$TARGET_HOME/.claude/hooks/agent-notepad/lib"

say() { printf '%s\n' "$*"; }

if ! command -v git >/dev/null 2>&1; then
  say "  WARN  git not on PATH — merge drivers not registered (conflicts stay manual)"
  exit 0
fi

DRIVER="$LIB_DIR/merge-session-index.py"
if [ ! -f "$DRIVER" ]; then
  # ⚠️ REPORTED, not silent. Registering a driver whose script is absent produces a git
  # config that names a file git cannot run — indistinguishable, from the config alone,
  # from a working one.
  say "  WARN  $DRIVER not present — merge driver NOT registered (conflicts stay manual)"
  exit 0
fi

# ⚠️ Override the global config file ONLY for a redirected HOME. Forcing
# GIT_CONFIG_GLOBAL=$HOME/.gitconfig on a real install would CREATE that file on a machine
# whose global config lives at the XDG path (~/.config/git/config) — and git reads XDG only
# when ~/.gitconfig is absent, so creating it would silently shadow every global setting the
# user has.
_cfg() {
  if [ "$TARGET_HOME" = "${HOME:-}" ]; then git config --global "$@"
  else GIT_CONFIG_GLOBAL="$TARGET_HOME/.gitconfig" git config --global "$@"; fi
}

WANT="python3 $DRIVER %O %A %B"
HAVE="$(_cfg merge.loom-session-index.driver 2>/dev/null || true)"

# ⚠️ COMPARE THE VALUE, NEVER MERE PRESENCE. The first version returned early whenever the key
# EXISTED, so it reported "already registered" over a path inside a deleted temp directory and
# left it there on every re-install. Idempotent means CONVERGES ON CORRECT, not "leaves
# whatever it finds".
if [ "$HAVE" = "$WANT" ]; then
  say "  ok    merge driver loom-session-index already registered (correct path)"
  exit 0
fi

if [ "$DRY" -eq 1 ]; then
  say "  would register merge.loom-session-index.driver -> $WANT"
  [ -n "$HAVE" ] && say "  would replace stale value      -> $HAVE"
  exit 0
fi

_cfg merge.loom-session-index.name \
  "agent-notepad sessions/index.json union, keyed by sessionId" 2>/dev/null || true
if _cfg merge.loom-session-index.driver "$WANT" 2>/dev/null; then
  if [ -n "$HAVE" ]; then
    say "  ok    merge driver RE-registered (stale path replaced: $HAVE)"
  else
    say "  ok    merge driver loom-session-index registered (sessions/index.json)"
  fi
else
  say "  WARN  could not register the merge driver — index.json conflicts stay manual"
fi
exit 0
