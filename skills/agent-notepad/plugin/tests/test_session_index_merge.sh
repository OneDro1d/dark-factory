#!/usr/bin/env bash
# The sessions/index.json merge driver: a real 3-way merge through git, plus every refusal.
#
# ⚠️ Driven through `git merge` in a temp repo, not by calling the script directly — the thing
# under test is that the DRIVER IS WIRED and behaves, not that a function returns a list. A
# script that works standalone and is never invoked is the estate's signature defect.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$(dirname "$HERE")/lib/merge-session-index.py"
. "$HERE/assert.sh"

_repo() { # prints a temp repo with the driver registered and the attribute set
  local d; d="$(mktemp -d)/np"; mkdir -p "$d/sessions"
  git -c init.defaultBranch=main -C "$d" init -q 2>/dev/null || { rm -rf "$d"; return 1; }
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" config merge.loom-session-index.driver "python3 $DRIVER %O %A %B"
  printf 'sessions/index.json merge=loom-session-index\n' > "$d/.gitattributes"
  printf '%s' "$d"
}

_idx() { printf '%s\n' "$2" > "$1/sessions/index.json"; }

_diverge() { # <repo> <ours-json> <theirs-json> -> merges theirs into ours
  local d="$1"
  _idx "$d" '[{"sessionId":"shared","turns":1}]'
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm base
  git -C "$d" checkout -qb other
  _idx "$d" "$3"; git -C "$d" commit -aqm theirs
  git -C "$d" checkout -q main
  _idx "$d" "$2"; git -C "$d" commit -aqm ours
  git -C "$d" merge other -m merge >/dev/null 2>&1
}

test_driver_exists() {
  assert_file_exists "$DRIVER" "merge-session-index.py exists"
}

# ⛔ THE CASE THAT RECURS. Two machines each append their own session.
test_union_keeps_both_sides() {
  local d; d="$(_repo)" || { _fail "git unavailable"; return; }
  _diverge "$d" \
    '[{"sessionId":"shared","turns":1},{"sessionId":"laptop","turns":2}]' \
    '[{"sessionId":"shared","turns":1},{"sessionId":"poland","turns":3}]'
  local out; out="$(cat "$d/sessions/index.json")"
  assert_contains "$out" "laptop" "our entry survives"
  assert_contains "$out" "poland" "their entry survives"
  # ⚠️ The whole point: VALID JSON. `merge=union` produces a missing comma here.
  ASSERT_CASES=$((ASSERT_CASES + 1))
  if printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    _pass
  else
    _fail "the merged index is not valid JSON"
  fi
  rm -rf "$(dirname "$d")"
}

# Same session on both sides -> keep the LATER measurement, never invent one.
test_same_session_keeps_later_measurement() {
  local d; d="$(_repo)" || { _fail "git unavailable"; return; }
  _diverge "$d" \
    '[{"sessionId":"s","turns":5,"lastInteractionAt":"2026-01-01"}]' \
    '[{"sessionId":"s","turns":9,"lastInteractionAt":"2026-06-01"}]'
  local out; out="$(cat "$d/sessions/index.json")"
  assert_contains "$out" '"turns": 9' "the later measurement wins"
  assert_not_contains "$out" '"turns": 5' "the earlier one is replaced, not duplicated"
  rm -rf "$(dirname "$d")"
}

# ⛔ REFUSE rather than write a default. An unparseable side must leave a conflict.
test_refuses_unparseable_side() {
  local d; d="$(_repo)" || { _fail "git unavailable"; return; }
  _diverge "$d" '[{"sessionId":"a"}]' 'this is not json at all'
  ASSERT_CASES=$((ASSERT_CASES + 1))
  if git -C "$d" ls-files -u sessions/index.json | grep -q .; then _pass
  else _fail "an unparseable side was merged instead of left as a conflict"; fi
  rm -rf "$(dirname "$d")"
}

test_refuses_non_list() {
  local d; d="$(_repo)" || { _fail "git unavailable"; return; }
  _diverge "$d" '[{"sessionId":"a"}]' '{"sessionId":"not-a-list"}'
  ASSERT_CASES=$((ASSERT_CASES + 1))
  if git -C "$d" ls-files -u sessions/index.json | grep -q .; then _pass
  else _fail "a non-list side was merged instead of left as a conflict"; fi
  rm -rf "$(dirname "$d")"
}

run_tests
