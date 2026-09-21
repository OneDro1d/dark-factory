#!/usr/bin/env bash
# U3 — Stop hook test (STUB mode).
# Builds a TEMP notepad (temp git repo, NO remote) + a sample transcript.jsonl,
# pipes hook JSON to hooks/stop.sh, and asserts:
#   - hook exits 0 and prints {} (allow)
#   - a new journal line is appended under sessions/<...>.jsonl
#     carrying the transcript's files-touched + commands
#   - sessions/index.json is upserted for the session
#   - a NEW session_id -> a NEW journal file; the prior journal is untouched (crit 2)
#   - the per-session cursor advances so re-parsing the transcript does NOT
#     duplicate already-journaled traces (files/commands since LAST stop)
# TEMP-ONLY + STUB: never touches a real notepad, ~/.claude, a real repo, or a live palace.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
HOOK="$ROOT/hooks/stop.sh"
. "$HERE/assert.sh"

# ⛔ THE EXIT CODE HAS TO SURVIVE A SUBSHELL, AND IT DID NOT. `_run_hook` used to set a plain
# HOOK_RC variable. Most call sites capture its stdout — `out="$(_run_hook ...)"` — which runs
# the whole function in a SUBSHELL, so that assignment was discarded and the later
# `assert_eq "0" "$HOOK_RC"` read whatever a PREVIOUS test had left in the parent shell.
# Measured 2026-09-20: `test_stop_appends_journal_and_upserts_index` was asserting the exit code
# of a hook run performed by `test_new_session_new_journal_prior_untouched`, which happens to run
# earlier alphabetically. It would have passed with the hook under test returning 1, and run on
# its own it would have died on an unbound variable instead. A check that cannot fail is not a
# check. The rc now goes through a file, which crosses the subshell boundary.
HOOK_RC_FILE="$(mktemp)"
_hook_rc() { cat "$HOOK_RC_FILE" 2>/dev/null; }


# --- scaffolding ------------------------------------------------------------

_scaffold_notepad() { # prints notepad root; a temp git repo with no remote
  local base np
  base="$(mktemp -d)"
  np="$base/proj-arbbot"
  mkdir -p "$np/sessions"
  : > "$np/NOTES.md"                 # NOTES.md marker => find_notepad resolves here
  printf '[]\n' > "$np/sessions/index.json"
  git -C "$np" init -q
  git -C "$np" config user.email t@t.t
  git -C "$np" config user.name t
  printf '%s' "$np"
}

# a sample transcript with one Edit (file-touch) + one Bash command + a user msg
_write_transcript_1() { # dir -> path
  local d="$1" tp="$1/transcript.jsonl"
  {
    printf '%s\n' '{"type":"user","message":{"content":"do the thing"}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/abs/code/alpha.go"}}]}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"go build ./..."}}]}}'
  } > "$tp"
  printf '%s' "$tp"
}

# append a SECOND turn (new Edit) to the same transcript
_append_transcript_2() { # path
  local tp="$1"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/abs/code/beta.go"}}]}}' >> "$tp"
}

_run_hook() { # np transcript session -> stdout(hook), sets HOOK_RC
  local np="$1" tp="$2" sid="$3"
  printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$tp" "$np" "$sid" \
    | bash "$HOOK"
  HOOK_RC=$?
  printf '%s' "$HOOK_RC" > "$HOOK_RC_FILE"   # survives `out="$(_run_hook ...)"`; see the note above
}

# --- tests ------------------------------------------------------------------

test_hook_exists_and_executable() {
  assert_file_exists "$HOOK" "hooks/stop.sh exists"
  if [ -x "$HOOK" ]; then _pass; else _fail "hooks/stop.sh is executable"; fi
  ASSERT_CASES=$((ASSERT_CASES + 1))
}

test_stop_appends_journal_and_upserts_index() {
  local np tp log out jf lines
  np="$(_scaffold_notepad)"
  tp="$(_write_transcript_1 "$np")"
  log="$(mktemp)"; rm -f "$log"

  out="$(_run_hook "$np" "$tp" "sess1")"

  assert_eq "0" "$(_hook_rc)" "hook exits 0"
  assert_eq "{}" "$out" "hook prints {} (allow)"

  # exactly one journal file was created for sess1
  jf="$(ls "$np"/sessions/*.jsonl 2>/dev/null | head -1)"
  assert_file_exists "$jf" "a session journal .jsonl was created"

  lines="$(cat "$jf")"
  assert_contains "$lines" "/abs/code/alpha.go" "journal captured the edited file (file-touch)"
  assert_contains "$lines" "go build ./..." "journal captured the bash command"

  # every journal line is valid JSON with the §6.2 schema keys
  local badkeys
  badkeys="$(jq -c 'select((.ts|not) or (.kind|not) or (has("refs")|not) or (has("commit")|not) or (.session|not))' "$jf" 2>/dev/null)"
  assert_eq "" "$badkeys" "every journal line matches the §6.2 event schema"

  # index upserted: one entry for sess1
  assert_eq "1" "$(jq 'length' "$np/sessions/index.json")" "index has one session entry"
  assert_eq "sess1" "$(jq -r '.[0].sessionId' "$np/sessions/index.json")" "index entry is sess1"
  assert_eq "1" "$(jq -r '.[0].turns' "$np/sessions/index.json")" "index turns == 1 after first stop"


  rm -rf "$(dirname "$np")" "$log"
}

test_second_stop_same_session_no_duplicate_and_turns_increment() {
  local np tp log jf a2_before a2_after alpha_count
  np="$(_scaffold_notepad)"
  tp="$(_write_transcript_1 "$np")"
  log="$(mktemp)"; rm -f "$log"

  _run_hook "$np" "$tp" "sess1" >/dev/null
  jf="$(ls "$np"/sessions/*.jsonl 2>/dev/null | head -1)"
  # alpha.go was journaled exactly once on the first stop
  alpha_count="$(grep -c '/abs/code/alpha.go' "$jf")"
  assert_eq "1" "$alpha_count" "alpha.go journaled once after first stop"

  # new work happens: a Write of beta.go is appended to the transcript
  _append_transcript_2 "$tp"
  _run_hook "$np" "$tp" "sess1" >/dev/null

  # SAME journal file reused (still exactly one .jsonl)
  assert_eq "1" "$(ls "$np"/sessions/*.jsonl 2>/dev/null | wc -l | tr -d ' ')" "same session reuses one journal file"
  # beta.go now present (new trace since last stop)
  assert_contains "$(cat "$jf")" "/abs/code/beta.go" "second stop journals the new file since last stop"
  # alpha.go still journaled exactly once (cursor prevents re-parsing old lines)
  alpha_count="$(grep -c '/abs/code/alpha.go' "$jf")"
  assert_eq "1" "$alpha_count" "cursor prevents duplicate journaling of old traces"
  # turns incremented
  assert_eq "2" "$(jq -r '.[0].turns' "$np/sessions/index.json")" "index turns == 2 after second stop"

  rm -rf "$(dirname "$np")" "$log"
}

test_new_session_new_journal_prior_untouched() { # crit 2
  local np tp log jf1 jf1_hash_before jf1_hash_after
  np="$(_scaffold_notepad)"
  tp="$(_write_transcript_1 "$np")"
  log="$(mktemp)"; rm -f "$log"

  _run_hook "$np" "$tp" "sessA" >/dev/null
  jf1="$(ls "$np"/sessions/*.jsonl 2>/dev/null | head -1)"
  jf1_hash_before="$(cksum < "$jf1")"

  # a different session id -> must create a NEW journal file
  _run_hook "$np" "$tp" "sessB" >/dev/null

  assert_eq "2" "$(ls "$np"/sessions/*.jsonl 2>/dev/null | wc -l | tr -d ' ')" "new session created a new journal file"
  jf1_hash_after="$(cksum < "$jf1")"
  assert_eq "$jf1_hash_before" "$jf1_hash_after" "prior session journal left untouched (crit 2)"
  assert_eq "2" "$(jq 'length' "$np/sessions/index.json")" "index has two session entries"

  rm -rf "$(dirname "$np")" "$log"
}

test_outside_notepad_is_noop() { # regression: degrade politely
  local sb tp out log
  sb="$(mktemp -d)"          # NOT a notepad (no NOTES.md)
  tp="$sb/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$tp"
  log="$(mktemp)"; rm -f "$log"

  out="$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"x"}' "$tp" "$sb" | bash "$HOOK")"
  assert_eq "0" "$?" "hook exits 0 outside a notepad"
  assert_eq "{}" "$out" "hook prints {} outside a notepad"
  # Nothing is written outside a notepad. (This used to also assert "no mirror ran";
  # the mirror tier was removed 2026-08-03, so only the no-op contract remains.)
  assert_eq "" "$(cat "$log" 2>/dev/null)" "no side-effect file outside a notepad"
  rm -rf "$sb" "$log"
}

# --- time-gated journal commit (2026-09-20) ---------------------------------
# ⛔ WHY THESE EXIST. This hook wrote sessions/ on every stop and never committed it, so
# the notepad tree was dirty permanently — and `git pull --ff-only` in session-start.sh
# REFUSES on a dirty tree. The push looked fine (it had nothing to push), so the failure
# was silent: the machine restored stale Notes forever. Measured: a notepad 20 commits
# behind for 17 days.
# ⚠️ Run RED FIRST. Against the pre-fix hook, cases 1-3 must FAIL; a suite that passes
# before and after has tested nothing.

test_journal_commit_leaves_sessions_clean() {
  local np tp out dirty
  np="$(_scaffold_notepad)"
  tp="$(_write_transcript_1 "$np")"

  export AGENT_NOTEPAD_SYNC_MIN=0        # 0 = sync on every stop, so the test is deterministic
  out="$(_run_hook "$np" "$tp" "sess-sync")"
  unset AGENT_NOTEPAD_SYNC_MIN

  # ⛔ The Stop hook must still allow, and must still cost the model nothing.
  # additionalContext on Stop forces a FULL EXTRA MODEL TURN; {} costs zero.
  assert_eq "{}" "$out" "hook still prints {} with the journal sync on"
  assert_eq "0" "$(_hook_rc)" "hook still exits 0 with the journal sync on"

  dirty="$(git -C "$np" status --porcelain -- sessions/ 2>/dev/null)"
  assert_eq "" "$dirty" "sessions/ is committed, so the tree is not left dirty"
  assert_contains "$(git -C "$np" log --oneline -1 2>/dev/null)" "journal sync" \
    "a journal-sync commit was created"

  rm -rf "$(dirname "$np")"
}

test_time_gate_holds_a_recent_sync() {
  local np tp before after
  np="$(_scaffold_notepad)"
  tp="$(_write_transcript_1 "$np")"

  export AGENT_NOTEPAD_SYNC_MIN=0
  _run_hook "$np" "$tp" "sess-gate" >/dev/null
  unset AGENT_NOTEPAD_SYNC_MIN
  before="$(git -C "$np" rev-parse HEAD 2>/dev/null)"
  # red-first anchor: without the fix there is no commit at all, so this is empty
  assert_contains "$(git -C "$np" log --oneline 2>/dev/null)" "journal sync" \
    "the first stop synced the journal"

  # second stop, moments later, with the real default-shaped interval
  _append_transcript_2 "$tp"
  export AGENT_NOTEPAD_SYNC_MIN=120
  _run_hook "$np" "$tp" "sess-gate" >/dev/null
  unset AGENT_NOTEPAD_SYNC_MIN
  after="$(git -C "$np" rev-parse HEAD 2>/dev/null)"

  assert_eq "$before" "$after" "a stop inside the interval does NOT make a second commit"
  rm -rf "$(dirname "$np")"
}

test_sync_never_commits_the_models_staged_work() {
  local np tp committed staged
  np="$(_scaffold_notepad)"
  tp="$(_write_transcript_1 "$np")"

  # the model is mid-edit and has staged its own work
  printf 'work in progress\n' > "$np/NOTES.md"
  git -C "$np" add NOTES.md

  export AGENT_NOTEPAD_SYNC_MIN=0
  _run_hook "$np" "$tp" "sess-staged" >/dev/null
  unset AGENT_NOTEPAD_SYNC_MIN

  # red-first anchor: the sync must actually have run, or the rest proves nothing
  assert_contains "$(git -C "$np" log --oneline 2>/dev/null)" "journal sync" \
    "the journal sync ran while the model had staged work"

  # ⛔ THE SAFETY PROPERTY: a hook-authored commit must never sweep in the model's work.
  # This is why the hook uses `git commit -- sessions/` and not a bare `git commit`.
  committed="$(git -C "$np" show --name-only --format= HEAD 2>/dev/null)"
  assert_not_contains "$committed" "NOTES.md" "the hook commit does NOT contain the model's file"
  staged="$(git -C "$np" diff --cached --name-only 2>/dev/null)"
  assert_contains "$staged" "NOTES.md" "the model's staged work is still staged afterwards"

  rm -rf "$(dirname "$np")"
}

test_no_sync_env_disables_the_commit() {
  local np tp out
  np="$(_scaffold_notepad)"
  tp="$(_write_transcript_1 "$np")"

  export AGENT_NOTEPAD_NO_SYNC=1 AGENT_NOTEPAD_SYNC_MIN=0
  out="$(_run_hook "$np" "$tp" "sess-off")"
  unset AGENT_NOTEPAD_NO_SYNC AGENT_NOTEPAD_SYNC_MIN

  assert_eq "{}" "$out" "hook still prints {} with the sync disabled"
  assert_eq "" "$(git -C "$np" log --oneline 2>/dev/null)" "no commit when AGENT_NOTEPAD_NO_SYNC=1"
  rm -rf "$(dirname "$np")"
}

run_tests
