#!/usr/bin/env bash
# validate.sh — the ONE command the installer's final box points at.
#
# Arms a throwaway notepad (validate-arm.sh), opens a fresh session in it running
# `/df-governed:validate`, then tears the scaffolding down and PROVES the tree is clean.
# This is the mechanism half of the fix VALIDATE-INSTALL.md's Part 2 preamble describes: the
# session needs a notepad because every mission-scoped gate walks up from cwd for NOTES.md,
# and it needs to be a FRESH session because a plugin materialised by an install is not
# loaded until the next one starts.
#
# MEASURED 2026-09-08, from `claude --help`: the CLI's own usage line is
# `claude [options] [command] [prompt]`, with a positional `prompt` argument documented as
# "Your prompt" -- an interactive session opened with that argument treats it as the first
# message, the same path a typed `/skill-name` resolves through (documented under --bare:
# "Skills still resolve via /skill-name"). So a slash command IS honoured as the initial
# prompt argument, and it is passed that way below, unquoted-by-shell as a single arg. This
# was checked against --help output, not against a live session -- this script's own
# contract forbids launching a real one to find out, so this is as far as "measured" goes
# without a session, and is why the check is spelled out here rather than assumed silently.
#
# `--kit-root` overrides discovery. Left unset, the kit root is resolved from a lockfile,
# walking UP from $PWD -- never from $0, because this script is meant to run vendored, under
# a Tier-3 instance's `vendor/dark-factory/boot-kit/scripts/`, where $0's own ancestry is the
# CACHE, not the kit being validated. This is the same walk Task 0 of VALIDATE-INSTALL.md
# does by hand, and the same rule `lock-verify.sh` follows for its `--lock` default.
#
# `--keep` skips teardown (and says so) -- useful for inspecting a failed run by hand.
# `VALIDATE_CLAUDE_BIN` overrides the binary, so a test suite can stub it and never launch a
# real session.
#
# Usage: validate.sh [--kit-root <dir> | --kit-root=<dir>] [--keep]
# Exit:  0 validated and torn down clean (or --keep, which always exits 0 and says so).
#        1 the session ran but teardown left drift.
#        2 bad arguments, no lockfile found, or no claude binary on PATH.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KIT_ROOT=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --kit-root)   KIT_ROOT="${2:?--kit-root needs a path}"; shift 2 ;;
    --kit-root=*) KIT_ROOT="${1#--kit-root=}"
                  [ -n "$KIT_ROOT" ] || { echo "FATAL: --kit-root= needs a path" >&2; exit 2; }
                  shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'FATAL unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -z "$KIT_ROOT" ]; then
  d="$PWD"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if ls "$d"/*.lock.json >/dev/null 2>&1; then
      KIT_ROOT="$d"
      break
    fi
    d="$(dirname "$d")"
  done
fi
if [ -z "$KIT_ROOT" ]; then
  printf 'FATAL: no *.lock.json found walking up from %s -- pass --kit-root\n' "$PWD" >&2
  exit 2
fi
[ -d "$KIT_ROOT" ] || { printf 'FATAL: no such directory: %s\n' "$KIT_ROOT" >&2; exit 2; }
KIT_ROOT="$(cd "$KIT_ROOT" && pwd)"

CLAUDE_BIN="${VALIDATE_CLAUDE_BIN:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  printf 'FATAL: no %s on PATH (set VALIDATE_CLAUDE_BIN to override)\n' "$CLAUDE_BIN" >&2
  exit 2
fi

ARM="$HERE/validate-arm.sh"
[ -f "$ARM" ] || { printf 'FATAL: missing sibling script: %s\n' "$ARM" >&2; exit 2; }

printf 'validate.sh: kit root %s\n' "$KIT_ROOT"

# "Leave the tree as you found it" is measured against how it was FOUND, not against empty.
# A kit that was already dirty before this run (an install that wrote probed.* into the
# lockfile, an operator's uncommitted edit) must not fail teardown for drift it did not cause.
STATUS_BEFORE=""
if git -C "$KIT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  STATUS_BEFORE="$(git -C "$KIT_ROOT" status --porcelain 2>/dev/null || true)"
fi

NP="$KIT_ROOT/.df-validate"
# A leftover from a `--keep` run is throwaway by contract; this is the one command the
# installer points at, so it must not strand the user on validate-arm.sh's refusal.
ARM_ARGS=()
if [ -e "$NP" ]; then
  printf 'validate.sh: removing leftover %s from a previous --keep run\n' "$NP"
  ARM_ARGS=(--force)
fi
bash "$ARM" "$KIT_ROOT" "${ARM_ARGS[@]+"${ARM_ARGS[@]}"}" || exit 1

if [ ! -d "$NP" ]; then
  printf 'FATAL: validate-arm.sh reported success but %s is missing\n' "$NP" >&2
  exit 1
fi

SESSION_RC=0
( cd "$NP" && "$CLAUDE_BIN" "/df-governed:validate" ) || SESSION_RC=$?
printf 'validate.sh: session exited %d\n' "$SESSION_RC"

REPORT_DATE="$(date -u +%Y-%m-%d)"
REPORT_BASENAME=""
if [ -f "$NP/REPORT.md" ]; then
  REPORT_BASENAME="VALIDATE-REPORT-$REPORT_DATE.md"
  cp "$NP/REPORT.md" "$KIT_ROOT/$REPORT_BASENAME"
  printf 'validate.sh: report copied to %s\n' "$KIT_ROOT/$REPORT_BASENAME"
else
  printf 'validate.sh: no REPORT.md in the armed notepad -- nothing copied\n'
fi

if [ "$KEEP" -eq 1 ]; then
  printf 'validate.sh: --keep set, leaving %s in place -- teardown skipped\n' "$NP"
  exit 0
fi

# --- teardown, then PROVE it -------------------------------------------------
rm -rf "$NP"
if git -C "$KIT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # ⚠️ MEASURED: --git-path is relative to $KIT_ROOT, not to this script's cwd -- see the
  # matching comment in validate-arm.sh. Same fix, same reason.
  EXCL="$(git -C "$KIT_ROOT" rev-parse --git-path info/exclude 2>/dev/null || true)"
  case "$EXCL" in
    /*) : ;;
    *)  EXCL="$KIT_ROOT/$EXCL" ;;
  esac
  if [ -n "$EXCL" ] && [ -f "$EXCL" ]; then
    grep -vxF '.df-validate/' "$EXCL" > "$EXCL.tmp" 2>/dev/null && mv "$EXCL.tmp" "$EXCL"
  fi
fi

printf 'validate.sh: git -C %s status --porcelain\n' "$KIT_ROOT"
STATUS="$(git -C "$KIT_ROOT" status --porcelain 2>/dev/null || true)"
printf '%s\n' "$STATUS"

printf 'validate.sh: ls .df-validate (must not exist)\n'
LS_OUT="$(cd "$KIT_ROOT" && ls .df-validate 2>&1)"
LS_RC=$?
printf '%s\n' "$LS_OUT"

# "Clean" means: nothing in the status now that was not in it BEFORE arming, except the ONE
# file this run knowingly left behind on purpose (the copied report) -- same rule
# VALIDATE-INSTALL.md's own teardown states for a human doing this by hand: "expect: empty,
# or ONLY files you knowingly changed." Anything else is unexplained and fails the check.
STATUS_UNEXPLAINED="$STATUS"
if [ -n "$STATUS_BEFORE" ]; then
  STATUS_UNEXPLAINED="$(printf '%s\n' "$STATUS_UNEXPLAINED" | grep -vxF -f <(printf '%s\n' "$STATUS_BEFORE") || true)"
fi
if [ -n "$REPORT_BASENAME" ]; then
  STATUS_UNEXPLAINED="$(printf '%s\n' "$STATUS_UNEXPLAINED" | grep -vF "$REPORT_BASENAME" || true)"
fi

CLEAN=1
[ -z "$STATUS_UNEXPLAINED" ] || CLEAN=0
[ "$LS_RC" -ne 0 ] || CLEAN=0

if [ "$CLEAN" -eq 1 ]; then
  printf 'validate.sh: teardown clean\n'
  exit 0
else
  printf 'validate.sh: teardown left drift -- see status above\n' >&2
  exit 1
fi
