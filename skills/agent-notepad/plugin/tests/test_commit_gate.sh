#!/usr/bin/env bash
# U8 — Commit gate + companion read-hooks test.
# Covers DESIGN §7.4 (UserPromptSubmit nudge), §7.5 (PreCompact floor),
# §7.6 (PreToolUse git-commit staleness gate), the D1/B9 mission-RUNNING
# tracker/mission-id predicate (DESIGN §2 Objective 6 + dispatcher amendments),
# and acceptance crit 7.
#
# TEMP-ONLY & SAFE:
#   - all git repos are throwaway `mktemp -d` temp repos (never a real repo);
#   - no `git push`/remote is ever touched;
#   - hooks are driven purely by piped stdin JSON;
#   - PreCompact writes only under temp cwd/notepad dirs.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
HOOKS="$ROOT/hooks"
TEMPLATE="$ROOT/notepad-template"
. "$HERE/assert.sh"

# Isolated git identity so temp commits don't depend on the user's global config.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# run_hook HOOK_PATH STDIN_JSON  -> captures stdout in $OUT, exit code in $RC
run_hook() {
  OUT="$(printf '%s' "$2" | "$1" 2>/dev/null)"
  RC=$?
}

# _mkrepo -> prints path to a fresh temp git repo carrying a df-context-store
_mkrepo() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  mkdir -p "$d/.claude/context" "$d/contracts"
  printf '# service map\n' > "$d/.claude/context/SERVICE-MAP.md"
  printf 'seed\n' > "$d/README.md"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -qm seed >/dev/null 2>&1
  printf '%s' "$d"
}

# _mknotepad -> prints path to a fresh temp notepad (NOTES.md marker + git repo,
# NO df-context-store — mirrors a real agent-notepad, which is notes, not code)
_mknotepad() {
  local d; d="$(mktemp -d)"
  printf '# notes\n' > "$d/NOTES.md"
  git -C "$d" init -q
  printf '%s' "$d"
}

# _set_mission_state NOTEPAD MISSION_ID STATE -> writes .df/missions/<id>/state
_set_mission_state() {
  mkdir -p "$1/.df/missions/$2"
  printf '%s\n' "$3" > "$1/.df/missions/$2/state"
}

# ── (a) benign non-commit command → allow ({}) ──────────────────────────────
test_noncommit_allows() {
  run_hook "$HOOKS/commit-gate.sh" \
    '{"tool_name":"Bash","tool_input":{"command":"ls -la /tmp"},"cwd":"/tmp"}'
  assert_eq "0" "$RC" "non-commit: exit 0"
  assert_eq "{}" "$OUT" "non-commit: emits {} (allow)"
}

test_git_status_allows() {
  run_hook "$HOOKS/commit-gate.sh" \
    '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp status"},"cwd":"/tmp"}'
  assert_eq "0" "$RC" "git status: exit 0"
  assert_eq "{}" "$OUT" "git status is not a commit → {}"
}

# ── (b) drift commit in a temp repo → block ─────────────────────────────────
test_drift_commit_blocks() {
  local repo; repo="$(_mkrepo)"
  # stage a STRUCTURAL change (a proto contract) but NOT any context-store file
  printf 'message X {}\n' > "$repo/contracts/x.proto"
  git -C "$repo" add "$repo/contracts/x.proto" >/dev/null 2>&1
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $repo commit -m change\"},\"cwd\":\"/tmp\"}"
  assert_eq "2" "$RC" "drift commit: exit 2 (block: documented exit code)"
  # valid JSON with a block decision
  printf '%s' "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1
  assert_eq "0" "$?" "drift commit: decision==block"
  assert_contains "$OUT" "x.proto" "block reason names the drifting structural file"
  assert_contains "$OUT" ".claude/context" "block reason points at the context store"
  rm -rf "$repo"
}

# ── (c) compliant commit (context store staged too) → allow ─────────────────
test_compliant_commit_allows() {
  local repo; repo="$(_mkrepo)"
  printf 'message Y {}\n' > "$repo/contracts/y.proto"
  printf '# service map\nupdated\n' > "$repo/.claude/context/SERVICE-MAP.md"
  git -C "$repo" add -A >/dev/null 2>&1
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $repo commit -m change\"},\"cwd\":\"/tmp\"}"
  assert_eq "0" "$RC" "compliant commit: exit 0"
  assert_eq "{}" "$OUT" "compliant commit (store staged) → {} (allow)"
  rm -rf "$repo"
}

# ── (d) non-structural commit → allow ───────────────────────────────────────
test_nonstructural_commit_allows() {
  local repo; repo="$(_mkrepo)"
  printf 'docs only\n' > "$repo/README.md"
  git -C "$repo" add -A >/dev/null 2>&1
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $repo commit -m docs\"},\"cwd\":\"/tmp\"}"
  assert_eq "0" "$RC" "non-structural commit: exit 0"
  assert_eq "{}" "$OUT" "non-structural change → {} (allow)"
  rm -rf "$repo"
}

# ── (e) commit outside a df-context-store repo → allow (nothing to govern) ───
test_commit_without_store_allows() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  printf 'x\n' > "$d/a.sql"           # structural, but repo has no .claude/context
  git -C "$d" add -A >/dev/null 2>&1
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $d commit -m x\"},\"cwd\":\"/tmp\"}"
  assert_eq "0" "$RC" "no-store repo: exit 0"
  assert_eq "{}" "$OUT" "no context store → gate abstains ({})"
  rm -rf "$d"
}

# ── (f) --no-verify bypass → allow even on drift ────────────────────────────
test_no_verify_bypasses() {
  local repo; repo="$(_mkrepo)"
  printf 'message Z {}\n' > "$repo/contracts/z.proto"
  git -C "$repo" add "$repo/contracts/z.proto" >/dev/null 2>&1
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $repo commit --no-verify -m x\"},\"cwd\":\"/tmp\"}"
  assert_eq "{}" "$OUT" "--no-verify bypasses the gate → {}"
  rm -rf "$repo"
}

# ── (g) env off bypass → allow even on drift ────────────────────────────────
test_env_off_bypasses() {
  local repo; repo="$(_mkrepo)"
  printf 'message Q {}\n' > "$repo/contracts/q.proto"
  git -C "$repo" add "$repo/contracts/q.proto" >/dev/null 2>&1
  OUT="$(printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $repo commit -m x\"},\"cwd\":\"/tmp\"}" \
        | AGENT_NOTEPAD_COMMIT_GATE=off "$HOOKS/commit-gate.sh" 2>/dev/null)"
  assert_eq "{}" "$OUT" "AGENT_NOTEPAD_COMMIT_GATE=off bypasses → {}"
  rm -rf "$repo"
}

# ── (h) PROBE 6 — RUNNING mission + no tracker/mission id in message → block ─
test_mission_running_probe6_blocks() {
  local np; np="$(_mknotepad)"
  _set_mission_state "$np" "M-KITV2-20260905" "RUNNING"
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$np\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $np commit -m wip\"}}"
  assert_eq "2" "$RC" "PROBE6: exit 2 (block: documented exit code)"
  printf '%s' "$OUT" | jq -e 'has("decision")' >/dev/null 2>&1
  assert_eq "0" "$?" "PROBE6: output carries a decision key (the shape this hook emits)"
  printf '%s' "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1
  assert_eq "0" "$?" "PROBE6: decision==block"
  assert_contains "$OUT" "M-KITV2-20260905" "PROBE6: reason names the RUNNING mission id"
  rm -rf "$np"
}

# ── (i) message names the mission id → allowed ──────────────────────────────
test_mission_running_mission_id_in_message_allows() {
  local np; np="$(_mknotepad)"
  _set_mission_state "$np" "M-KITV2-20260905" "RUNNING"
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$np\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $np commit -m 'map: M-KITV2-20260905 frontier'\"}}"
  assert_eq "0" "$RC" "mission-id message: exit 0"
  assert_eq "{}" "$OUT" "mission-id message satisfies the rule → falls through to {} (no context store)"
  rm -rf "$np"
}

# ── (j) message names a tracker item id → allowed ───────────────────────────
test_mission_running_tracker_id_in_message_allows() {
  local np; np="$(_mknotepad)"
  _set_mission_state "$np" "M-KITV2-20260905" "RUNNING"
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$np\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $np commit -m 'close 12983000509'\"}}"
  assert_eq "0" "$RC" "tracker-id message: exit 0"
  assert_eq "{}" "$OUT" "tracker-id message satisfies the rule → {}"
  rm -rf "$np"
}

# ── (k) -F <file> with a mission id inside → allowed; missing file → block ──
test_mission_running_file_message_allows_and_missing_blocks() {
  local np; np="$(_mknotepad)"
  _set_mission_state "$np" "M-KITV2-20260905" "RUNNING"
  printf 'close 12983000509\n' > "$np/msg.txt"

  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$np\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $np commit -F msg.txt\"}}"
  assert_eq "0" "$RC" "-F with mission id: exit 0"
  assert_eq "{}" "$OUT" "-F msg.txt (mission id inside) → {}"

  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$np\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $np commit -F missing.txt\"}}"
  assert_eq "2" "$RC" "-F missing.txt: exit 2 (block: documented exit code)"
  printf '%s' "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1
  assert_eq "0" "$?" "-F missing.txt: decision==block (unreadable file)"
  rm -rf "$np"
}

# ── (l) --no-verify does NOT bypass the mission predicate ───────────────────
test_mission_running_no_verify_still_blocks() {
  local np; np="$(_mknotepad)"
  _set_mission_state "$np" "M-KITV2-20260905" "RUNNING"
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$np\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $np commit --no-verify -m wip\"}}"
  assert_eq "2" "$RC" "--no-verify + mission RUNNING: exit 2 (block: documented exit code)"
  printf '%s' "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1
  assert_eq "0" "$?" "--no-verify does not bypass the mission gate: decision==block"
  assert_contains "$OUT" "--no-verify does not bypass the mission commit gate" \
    "reason explicitly says --no-verify does not bypass"
  rm -rf "$np"
}

# ── (m) -C/-c message-reuse → block (message not inspectable) ───────────────
test_mission_running_message_reuse_blocks() {
  local np; np="$(_mknotepad)"
  _set_mission_state "$np" "M-KITV2-20260905" "RUNNING"
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$np\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $np commit -C HEAD\"}}"
  assert_eq "2" "$RC" "commit -C HEAD (reuse): exit 2 (block: documented exit code)"
  printf '%s' "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1
  assert_eq "0" "$?" "commit -C HEAD (reuse): decision==block"
  assert_contains "$OUT" "not inspectable" "reuse reason says the message is not inspectable"
  rm -rf "$np"
}

# ── (n) no message flag at all (editor would open) → block ──────────────────
test_mission_running_no_message_flag_blocks() {
  local np; np="$(_mknotepad)"
  _set_mission_state "$np" "M-KITV2-20260905" "RUNNING"
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$np\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $np commit\"}}"
  assert_eq "2" "$RC" "commit (no -m): exit 2 (block: documented exit code)"
  printf '%s' "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1
  assert_eq "0" "$?" "commit (no -m): decision==block"
  assert_contains "$OUT" "an editor would open" "reason names the editor-would-open case"
  rm -rf "$np"
}

# ── (o) a flag missing its required value → fail-closed parse-error block ───
test_mission_running_missing_value_parse_error_blocks() {
  local np; np="$(_mknotepad)"
  _set_mission_state "$np" "M-KITV2-20260905" "RUNNING"
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$np\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $np commit -m\"}}"
  assert_eq "2" "$RC" "commit -m <nothing>: exit 2 (block: documented exit code)"
  printf '%s' "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1
  assert_eq "0" "$?" "commit -m <nothing>: decision==block (fail closed)"
  assert_contains "$OUT" "commit-gate: could not parse the commit command" \
    "parse-error reason carries the documented prefix"
  rm -rf "$np"
}

# ── (p) mission state DONE (not RUNNING) → pre-change behaviour: {} ─────────
test_mission_state_done_is_pre_change_behaviour() {
  local np; np="$(_mknotepad)"
  _set_mission_state "$np" "M-KITV2-20260905" "DONE"
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$np\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $np commit -m wip\"}}"
  assert_eq "0" "$RC" "mission DONE: exit 0"
  assert_eq "{}" "$OUT" "mission DONE (not RUNNING): pre-change behaviour, notepad needs no df-context-store → {}"
  rm -rf "$np"
}

# ── (q) commit in a repo with no notepad ancestor (no NOTES.md) → {} ────────
test_commit_outside_any_notepad_allows() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$d\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $d commit -m wip\"}}"
  assert_eq "0" "$RC" "commit outside notepad: exit 0"
  assert_eq "{}" "$OUT" "no NOTES.md ancestor → mission predicate doesn't apply → {}"
  rm -rf "$d"
}

# ── (r) old df-context-store rule still fires when a RUNNING mission message
#        satisfies the new rule but the repo also drifts — both predicates live
#        in the same file and must not shadow each other. The code repo is
#        nested INSIDE the notepad tree so notepad resolution (from `-C`) finds
#        the same NOTES.md ancestor the mission lives under. ─────────────────
test_mission_ok_but_old_rule_still_blocks_drift() {
  local np repo
  np="$(mktemp -d)"
  printf '# notes\n' > "$np/NOTES.md"
  _set_mission_state "$np" "M-KITV2-20260905" "RUNNING"
  repo="$np/coderepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  mkdir -p "$repo/.claude/context" "$repo/contracts"
  printf '# service map\n' > "$repo/.claude/context/SERVICE-MAP.md"
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" add -A >/dev/null 2>&1
  git -C "$repo" commit -qm seed >/dev/null 2>&1
  printf 'message X {}\n' > "$repo/contracts/x.proto"
  git -C "$repo" add "$repo/contracts/x.proto" >/dev/null 2>&1
  run_hook "$HOOKS/commit-gate.sh" \
    "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$repo\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $repo commit -m 'M-KITV2-20260905 change'\"}}"
  assert_eq "2" "$RC" "mission-ok, structural drift: exit 2 (block: documented exit code)"
  printf '%s' "$OUT" | jq -e '.decision=="block"' >/dev/null 2>&1
  assert_eq "0" "$?" "mission id satisfies new rule, but old df-context-store rule still blocks the drift"
  assert_contains "$OUT" "x.proto" "old-rule reason still names the drifting structural file"
  rm -rf "$np"
}

# ── user-prompt.sh pipe-test: valid JSON, exit 0, mentions NOTES.md ─────────
test_user_prompt_valid_json() {
  run_hook "$HOOKS/user-prompt.sh" '{"cwd":"/tmp","prompt":"hi"}'
  assert_eq "0" "$RC" "user-prompt: exit 0"
  printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1
  assert_eq "0" "$?" "user-prompt: valid JSON with additionalContext"
  assert_contains "$OUT" "NOTES.md" "user-prompt: nudges about NOTES.md"
}

test_user_prompt_in_notepad_names_path() {
  # scaffold a temp notepad from the template and point cwd at it
  local base np; base="$(mktemp -d)"; np="$base/proj-demo"
  mkdir -p "$np"; cp -R "$TEMPLATE/." "$np/"
  run_hook "$HOOKS/user-prompt.sh" "{\"cwd\":\"$np\",\"prompt\":\"hi\"}"
  assert_eq "0" "$RC" "user-prompt(notepad): exit 0"
  assert_contains "$OUT" "$np/NOTES.md" "user-prompt(notepad): names the notepad NOTES.md path"
  rm -rf "$base"
}

# ── pre-compact.sh pipe-test: valid JSON, exit 0 ────────────────────────────
test_pre_compact_valid_json_outside_notepad() {
  local d; d="$(mktemp -d)"
  run_hook "$HOOKS/pre-compact.sh" \
    "{\"cwd\":\"$d\",\"session_id\":\"s1\",\"trigger\":\"manual\",\"transcript_path\":\"\"}"
  assert_eq "0" "$RC" "pre-compact(outside): exit 0"
  printf '%s' "$OUT" | jq -e '.' >/dev/null 2>&1
  assert_eq "0" "$?" "pre-compact(outside): stdout is valid JSON"
  rm -rf "$d"
}

test_pre_compact_floors_into_notepad() {
  # build a notepad + a tiny fake transcript, then run PreCompact
  local base np tp; base="$(mktemp -d)"; np="$base/proj-demo"
  mkdir -p "$np"; cp -R "$TEMPLATE/." "$np/"
  tp="$base/transcript.jsonl"
  # split the secret prefix at runtime so GitHub push-protection can't flag it
  local ghp; ghp="ghp""_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  {
    printf '{"type":"user","message":{"content":"implement the arb bot; token=%s"}}\n' "$ghp"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/code/arb/main.go"}}]}}\n'
  } > "$tp"
  run_hook "$HOOKS/pre-compact.sh" \
    "{\"cwd\":\"$np\",\"session_id\":\"s9\",\"trigger\":\"auto\",\"transcript_path\":\"$tp\"}"
  assert_eq "0" "$RC" "pre-compact(notepad): exit 0"
  printf '%s' "$OUT" | jq -e '.' >/dev/null 2>&1
  assert_eq "0" "$?" "pre-compact(notepad): stdout is valid JSON"
  # floor block landed in NOTES.md, redacted, and a journal entry exists
  assert_contains "$(cat "$np/NOTES.md")" "PreCompact floor" "NOTES.md carries the floor block"
  assert_not_contains "$(cat "$np/NOTES.md")" "$ghp" "floor redacts the token literal"
  local jcount; jcount="$(ls "$np/sessions/"*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "1" "$jcount" "pre-compact appended exactly one session journal"
  assert_contains "$(cat "$np/sessions/"*.jsonl)" "precompact" "journal has a precompact milestone entry"
  rm -rf "$base"
}

run_tests
