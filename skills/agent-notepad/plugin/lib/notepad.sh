#!/usr/bin/env bash
# lib/notepad.sh — agent-notepad model helpers (U1).
# Pure bash, no external deps beyond coreutils. Sourced by hooks (U2/U3) and tests.
# A "notepad" is a standalone git repo whose marker is a NOTES.md at its root
# (DESIGN §5–§6). These helpers never mutate a real palace and never `cd`.

# find_notepad CWD
#   Prints the notepad root (nearest ancestor of CWD containing NOTES.md) and returns 0.
#   Prints nothing and returns 1 when CWD is not inside a notepad.
#   Read-only: pure directory walk, no side effects.
find_notepad() {
  local dir="${1:-$PWD}"
  # normalize to an absolute path if possible
  if [ -d "$dir" ]; then
    dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1
  fi
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/NOTES.md" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  # check filesystem root explicitly
  if [ -f "/NOTES.md" ]; then
    printf '%s\n' "/"
    return 0
  fi
  return 1
}

# new_journal_file NOTEPAD_ROOT [SESSION_ID]
#   Creates (touch) and prints a fresh append-only journal file path under
#   <notepad>/sessions/<ISO8601>_<id>.jsonl (DESIGN §6.2). One file per session.
#   SESSION_ID defaults to a short random id. The ':' in the ISO timestamp is
#   replaced with '-' to keep the filename portable.
new_journal_file() {
  local np="$1" sid="${2:-}"
  [ -n "$np" ] || return 1
  mkdir -p "$np/sessions"
  if [ -z "$sid" ]; then
    # short, filename-safe random id
    sid="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ -n "$sid" ] || sid="$$"
  fi
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local jf="$np/sessions/${ts}_${sid}.jsonl"
  : >> "$jf"
  printf '%s\n' "$jf"
}

# append_journal JOURNAL_FILE JSON_LINE
#   Appends one JSONL record (append-only, never rewrites) to the journal file.
#   The caller is responsible for JSON validity; this helper only enforces
#   single-line append and creates the parent dir if needed.
append_journal() {
  local jf="$1" line="$2"
  [ -n "$jf" ] || return 1
  mkdir -p "$(dirname "$jf")"
  # collapse any embedded newlines so one record == one line
  printf '%s\n' "$(printf '%s' "$line" | tr '\n' ' ')" >> "$jf"
}
