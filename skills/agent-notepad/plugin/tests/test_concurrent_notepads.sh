#!/usr/bin/env bash
# crit 1 — two concurrent notepads (same prefix, different objectives) operate
# with independent NOTES/journal/index and ZERO cross-contamination when their
# Stop hooks run interleaved. STUB mode, temp dirs only — never touches a real
# notepad, ~/.claude, or the live palace.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
HOOK="$ROOT/hooks/stop.sh"
. "$HERE/assert.sh"


_scaffold() { # name -> notepad root (temp git repo, no remote)
  local base np; base="$(mktemp -d)"; np="$base/$1"
  mkdir -p "$np/sessions"; : > "$np/NOTES.md"; printf '[]\n' > "$np/sessions/index.json"
  git -C "$np" init -q; git -C "$np" config user.email t@t.t; git -C "$np" config user.name t
  printf '%s' "$np"
}

_transcript() { # dir absfile -> transcript path
  local d="$1" f="$2" tp="$1/transcript.jsonl"
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"$f\"}}]}}" > "$tp"
  printf '%s' "$tp"
}

_stop() { # np tp sid
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$2" "$1" "$3" | bash "$HOOK" >/dev/null
}

test_two_notepads_no_cross_contamination() {
  local a b ta tb ja jb
  a="$(_scaffold proj-arbbot)"; b="$(_scaffold proj-bugs)"
  ta="$(_transcript "$a" /abs/arbbot/alpha.go)"
  tb="$(_transcript "$b" /abs/bugs/beta.go)"

  # interleave: A, B, A again
  _stop "$a" "$ta" "sa1"
  _stop "$b" "$tb" "sb1"
  _stop "$a" "$ta" "sa1"

  ja="$(cat "$a"/sessions/*.jsonl 2>/dev/null)"
  jb="$(cat "$b"/sessions/*.jsonl 2>/dev/null)"

  assert_contains "$ja" "/abs/arbbot/alpha.go" "notepad A journaled its own file"
  assert_not_contains "$ja" "/abs/bugs/beta.go" "notepad A did NOT capture B's file"
  assert_contains "$jb" "/abs/bugs/beta.go" "notepad B journaled its own file"
  assert_not_contains "$jb" "/abs/arbbot/alpha.go" "notepad B did NOT capture A's file"

  # independent indexes, each with its own single session
  assert_eq "1" "$(jq 'length' "$a/sessions/index.json")" "A index has exactly one session"
  assert_eq "sa1" "$(jq -r '.[0].sessionId' "$a/sessions/index.json")" "A index owns sa1"
  assert_eq "1" "$(jq 'length' "$b/sessions/index.json")" "B index has exactly one session"
  assert_eq "sb1" "$(jq -r '.[0].sessionId' "$b/sessions/index.json")" "B index owns sb1"

  # separate git repos (independent commit streams by construction)
  assert_dir_exists "$a/.git" "A is its own git repo"
  assert_dir_exists "$b/.git" "B is its own git repo"

  rm -rf "$(dirname "$a")" "$(dirname "$b")"
}

run_tests
