#!/usr/bin/env bash
# mission-tick.sh — background monitor for objective 5 (a cron tick reminds the agent
# a mission is unfinished). Declared in monitors/monitors.json as "always", so a fresh
# session (including one started by /clear) starts a new copy of this loop.
#
# STRICTLY READ-ONLY. This script only reads state files and prints lines to stdout —
# it never writes under .df/ or the notepad, and it must never gain mkdir, touch, rm,
# mv, tee, sed -i, or a shell write redirection. tests/test-mission-tick.sh asserts
# this statically. Generic on purpose: no estate names, hosts, people, or machine paths.
set -u

# Walk UP from $PWD looking for NOTES.md — the notepad root marker. $PWD is the
# session working directory the monitor starts in, per the monitors doc.
find_notepad() {
  local dir="$PWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/NOTES.md" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# The mission's owner, if any: .df/missions/<id>/owner holds one line, the owning session's
# id. This session's own id is CLAUDE_CODE_SESSION_ID — measured (this monitor gets no hook
# payload, only its environment; the harness sets this var, not the CLAUDE_SESSION_ID the SPEC
# guessed at). Empty/unset is a valid "I don't know who I am" and is treated like a mismatch.
owner_of() {   # args: notepad, mission id. prints the owner id, or nothing
  local f="$1/.df/missions/$2/owner"
  [ -f "$f" ] || return 1
  tr -d '[:space:]' < "$f"
}

# Newest mtime, in epoch seconds, of any sessions/*<owner>* file — the session journal this
# notepad's Stop hook writes (CLAUDE.md: "sessions/<ISO8601>_<id>.jsonl"). No match at all is
# staleness too: the owner never wrote here, which is at least as telling as writing long ago.
newest_session_mtime() {   # args: notepad, owner id. prints an epoch-seconds mtime, or nothing
  local notepad="$1" owner="$2" f newest="" nt
  [ -n "$owner" ] || return 1
  for f in "$notepad"/sessions/*"$owner"*; do
    [ -f "$f" ] || continue
    nt="$(date -r "$f" +%s)"
    if [ -z "$newest" ] || [ "$nt" -gt "$newest" ]; then newest="$nt"; fi
  done
  [ -n "$newest" ] || return 1
  printf '%s' "$newest"
}

tick_once() {
  local notepad f id iso now mt mins owner me sm age_h stale
  notepad="$(find_notepad)" || return 0
  now="$(date +%s)"
  for f in "$notepad"/.df/missions/*/state; do
    [ -f "$f" ] || continue
    [ "$(head -n1 "$f")" = "RUNNING" ] || continue
    id="${f%/state}"
    id="${id##*/}"
    iso="$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ)"
    mt="$(date -r "$f" +%s)"
    mins=$(( (now - mt) / 60 ))

    owner="$(owner_of "$notepad" "$id")" || owner=""
    me="${CLAUDE_CODE_SESSION_ID:-}"
    if [ -n "$owner" ] && [ "$owner" != "$me" ]; then
      stale=0
      if sm="$(newest_session_mtime "$notepad" "$owner")"; then
        age_h=$(( (now - sm) / 3600 ))
        [ "$age_h" -gt "${DF_OWNER_STALE_HOURS:-6}" ] && stale=1
      else
        stale=1
      fi
      if [ "$stale" -eq 0 ]; then
        # ⚠️ STDERR, deliberately. This script runs as a Monitor, and every STDOUT line is a
        # wake-up event for the session that armed it. A live owner elsewhere is exactly the
        # case that must NOT wake this session — that manufactured wake-up is the defect the
        # owner file exists to remove. Say it where a reader of the log can see it, and nowhere
        # the harness will turn into a notification.
        printf 'mission %s: owned by %s, not this session\n' "$id" "${owner:0:8}" >&2
        continue
      fi
      printf 'mission-tick: %s is RUNNING (state written %s, %s min ago) — owner may be gone — read MAP.md, take the frontier ticket, or mark the state DONE\n' "$id" "$iso" "$mins"
      continue
    fi

    printf 'mission-tick: %s is RUNNING (state written %s, %s min ago) — read MAP.md, take the frontier ticket, or mark the state DONE\n' "$id" "$iso" "$mins"
  done
}

while true; do
  tick_once
  [ "${DF_TICK_ONCE:-0}" = "1" ] && exit 0
  sleep "${DF_TICK_SECONDS:-1020}"
done
