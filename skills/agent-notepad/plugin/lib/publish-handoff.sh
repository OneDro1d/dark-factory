#!/usr/bin/env bash
# lib/publish-handoff.sh — agent-notepad U9: publish a deliberate Handoff doc
# (DESIGN §9, acceptance crit 8).
#
# Writes the structured handoff to <notepad>/handoffs/<date>-<topic>.md — INSIDE
# the notepad, NOT a temp/OS dir — redacts secrets, then FORCES a git push of the
# notepad (git add/commit/push, all best-effort so a flaky remote never blocks
# the caller). The continuous tier is Notes (NOTES.md + journal); a Handoff is
# the deliberate, structured summary this helper publishes.
#
# Usage:
#   publish-handoff.sh <notepad-root> <topic> [body-file]
#   printf '<body>' | publish-handoff.sh <notepad-root> <topic>
# Prints the absolute path of the handoff doc it wrote.
#
# Target overridable (tests point these at TEMP, never a real repo/remote):
#   <notepad-root>            — the notepad to publish into (arg, not hardwired).
#   AGENT_NOTEPAD_DATE        — override the date stamp (default: UTC today).
#   AGENT_NOTEPAD_PUSH_LOG    — file to append push attempts to (observability).
#
# Boundary: writes ONLY under the given notepad; refuses if it is not a notepad
# (no NOTES.md at root). Never touches ~/.claude or any dir outside the notepad.
set -u

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_ROOT="$(dirname "$_DIR")"
# shellcheck source=./redact.sh
. "$_ROOT/lib/redact.sh" 2>/dev/null || true
# shellcheck source=./notepad.sh
. "$_ROOT/lib/notepad.sh" 2>/dev/null || true

_slugify() { # TEXT -> lowercase, alnum runs collapsed to single hyphens
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

publish_handoff() { # NOTEPAD_ROOT TOPIC [BODY_FILE]
  local np="${1:-}" topic="${2:-handoff}" body_file="${3:-}"
  [ -n "$np" ] || { printf 'publish-handoff: missing notepad root\n' >&2; return 2; }

  # Resolve/verify the notepad: the given root must itself be (or sit under) a
  # notepad. Refuse otherwise so we never write outside a notepad.
  local root
  root="$(find_notepad "$np" 2>/dev/null)" || {
    printf 'publish-handoff: %s is not a notepad (no NOTES.md)\n' "$np" >&2
    return 3
  }

  local date_stamp slug hf
  date_stamp="${AGENT_NOTEPAD_DATE:-$(date -u +%Y-%m-%d)}"
  slug="$(_slugify "$topic")"
  [ -n "$slug" ] || slug="handoff"
  mkdir -p "$root/handoffs"
  hf="$root/handoffs/${date_stamp}-${slug}.md"

  # Body from stdin unless a body file is given.
  local raw
  if [ -n "$body_file" ] && [ -f "$body_file" ]; then
    raw="$(cat "$body_file")"
  else
    raw="$(cat)"
  fi

  # Compose the structured doc, then redact secrets over the WHOLE thing.
  {
    printf '# Handoff: %s\n\n' "$topic"
    printf '**Date:** %s  ·  **Notepad:** %s\n\n' "$date_stamp" "$(basename "$root")"
    printf '> Deliberate **Handoff** (structured, on-demand). The continuous tier is\n'
    printf '> **Notes** (NOTES.md + journal); this doc summarizes but does not replace it.\n\n'
    printf '%s\n' "$raw"
  } | redact_secrets > "$hf"

  # --- FORCE a git push of the notepad (best-effort at each step) -------------
  local plog="${AGENT_NOTEPAD_PUSH_LOG:-}"
  git -C "$root" add "handoffs/${date_stamp}-${slug}.md" >/dev/null 2>&1 || true
  git -C "$root" commit -qm "handoff: ${topic} (${date_stamp})" >/dev/null 2>&1 || true
  # record that a push was attempted (observability), then attempt it.
  [ -n "$plog" ] && printf 'PUSH %s %s\n' "$root" "$hf" >> "$plog" 2>/dev/null || true
  git -C "$root" push >/dev/null 2>&1 || true

  printf '%s\n' "$hf"
  return 0
}

# Run when invoked directly (not sourced).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  publish_handoff "$@"
fi
