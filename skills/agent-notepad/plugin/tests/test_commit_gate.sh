#!/usr/bin/env bash
# U8 — Commit gate + companion read-hooks test.
# Covers DESIGN §7.4 (UserPromptSubmit nudge), §7.5 (PreCompact floor),
# §7.6 (PreToolUse git-commit staleness gate) and acceptance crit 7.
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
  assert_eq "0" "$RC" "drift commit: exit 0 (gate never crashes the tool call)"
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
