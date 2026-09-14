#!/usr/bin/env bash
# link.sh — put df-start, df-open and df-bg on PATH (or take them off).
#
#   bash bin/link.sh                      link as df-start / df-open / df-bg
#   bash bin/link.sh --prefix acme        link as acme-df-start / acme-df-open / acme-df-bg
#   bash bin/link.sh --unlink             remove ONLY links that point into this kit's bin/
#   bash bin/link.sh --prefix X --unlink  the same, for that prefix
#
# ⛔ WHY --prefix EXISTS. These names are global to a machine, and the loop below REFUSES to
# overwrite a name that is already taken. One person commonly holds SEVERAL kits — one per
# organisation they work with, four on the machine where this was measured — so with fixed
# names whichever kit ran this second got nothing, and said so in a line nobody reads twice.
# A single `df-start` on PATH can only ever point into one kit.
#
# The prefix is not decoration: df-start reads the name it was INVOKED as and opens that
# organisation's mission skill (<prefix>-df-start → /<prefix>-dark-factory). So ONE
# implementation, here in Tier 1, serves every organisation, and no kit needs its own fork of
# these files just to choose a skill. Use the same name the organisation's mission skill uses.
#
# A separate step, not part of install.sh: install.sh is kept byte-identical to Tier 1's.
# It never overwrites a regular file or a link that points somewhere else.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDIR="${LOOM_BIN:-$HOME/.local/bin}"
MODE=link
PREFIX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --unlink) MODE=unlink; shift ;;
    --prefix)
      [ -n "${2:-}" ] || { echo "link.sh: --prefix needs a short name — the one your mission skill uses" >&2; exit 2; }
      case "$2" in
        *[!a-z0-9-]*|-*|*-) echo "link.sh: --prefix must be lower-case letters, digits and inner hyphens: $2" >&2; exit 2 ;;
      esac
      PREFIX="$2"; shift 2 ;;
    *) echo "link.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
RC=0
mkdir -p "$BINDIR"
for name in df-start df-open df-bg; do
  src="$HERE/$name"; dst="$BINDIR/${PREFIX:+$PREFIX-}$name"
  if [ "$MODE" = unlink ]; then
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then rm -f "$dst"; echo "removed $dst"
    elif [ -e "$dst" ] || [ -L "$dst" ]; then echo "kept    $dst (not a link into this kit)"
    fi
    continue
  fi
  [ -f "$src" ] || { echo "MISSING $src" >&2; RC=2; continue; }
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then echo "ok      $dst"; continue; fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    echo "REFUSED $dst already exists and is not this kit's link — remove it yourself if you mean" >&2
    echo "        to replace it, or give this kit its own names: --prefix <estate>" >&2
    RC=2; continue
  fi
  ln -s "$src" "$dst"; echo "linked  $dst -> $src"
done
if [ "$MODE" = link ]; then
  case ":$PATH:" in *":$BINDIR:"*) ;; *) echo "WARN    $BINDIR is not on your PATH — add it, then open a new shell." ;; esac
  [ -n "$PREFIX" ] && echo "note    missions from this kit open /${PREFIX}-dark-factory (taken from the linked name)"
fi
exit "$RC"
