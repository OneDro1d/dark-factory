#!/usr/bin/env bash
# U2 — SessionStart restore + best-effort pull hook test.
# Exercises hooks/session-start.sh end-to-end via stdin JSON:
#   (a) inside a temp notepad  -> emits dual-field JSON carrying NOTES/DIGEST/manifest content
#   (b) outside a notepad      -> emits {} (degrades to handoff-auto behavior)
#   - completes fast (file reads only; pull is bounded/best-effort)
#   - exit 0 always
# TEMP-ONLY: operates on mktemp -d dirs and temp git repos; never touches a real
# notepad, ~/.claude, or the live palace. Pull is disabled (AGENT_NOTEPAD_NO_PULL=1)
# in content assertions to keep them hermetic; one case exercises the pull path
# against a temp git repo with NO remote (returns instantly, proves non-blocking).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
HOOK="$ROOT/hooks/session-start.sh"
. "$HERE/assert.sh"

# scaffold a temp notepad with a sentinel in NOTES.md
_scaffold() { # prints notepad root
  local base np
  base="$(mktemp -d)"
  np="$base/proj-arbbot"
  mkdir -p "$np/sessions"
  cat > "$np/NOTES.md" <<'EOF'
# proj-arbbot NOTES
## Current goal
NOTES_SENTINEL_ARBBOT restore the arbitrage bot p&l calc
## Next action
wire the exchange adapter
EOF
  cat > "$np/DIGEST.md" <<'EOF'
# digest
DIGEST_SENTINEL cross-scope: proj-bugs touched the same adapter
EOF
  cat > "$np/repos.manifest.json" <<'EOF'
{ "repos": [ { "path": "/abs/code/MANIFEST_SENTINEL", "branch": "main", "role": "primary" } ], "requires_df_context_store": true }
EOF
  printf '%s' "$np"
}

_run_hook() { # cwd -> hook stdout (env: AGENT_NOTEPAD_NO_PULL honored by caller)
  printf '{"hookEventName":"SessionStart","cwd":"%s"}' "$1" | bash "$HOOK"
}

test_hook_exists_and_executable() {
  assert_file_exists "$HOOK" "session-start.sh exists"
  ASSERT_CASES=$((ASSERT_CASES + 1))
  if [ -x "$HOOK" ]; then _pass; else _fail "session-start.sh is chmod +x"; fi
}

test_inside_notepad_injects_notes() {
  local np out; np="$(_scaffold)"
  out="$(AGENT_NOTEPAD_NO_PULL=1 _run_hook "$np")"
  assert_contains "$out" "NOTES_SENTINEL_ARBBOT" "output carries NOTES.md content"
  assert_contains "$out" "DIGEST_SENTINEL" "output carries DIGEST.md content"
  assert_contains "$out" "MANIFEST_SENTINEL" "output carries repos.manifest.json content"
  # valid JSON with the dual-field SessionStart contract
  assert_eq "SessionStart" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" \
    "hookSpecificOutput.hookEventName is SessionStart"
  assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" \
    "NOTES_SENTINEL_ARBBOT" "additionalContext carries notes"
  assert_contains "$(printf '%s' "$out" | jq -r '.systemMessage')" \
    "NOTES_SENTINEL_ARBBOT" "systemMessage carries notes"
  rm -rf "$(dirname "$np")"
}

test_inside_notepad_from_subdir() {
  local np out; np="$(_scaffold)"
  out="$(AGENT_NOTEPAD_NO_PULL=1 _run_hook "$np/sessions")"
  assert_contains "$out" "NOTES_SENTINEL_ARBBOT" "walks up from subdir cwd"
  rm -rf "$(dirname "$np")"
}

test_digest_absent_still_injects() {
  local np out; np="$(_scaffold)"
  rm -f "$np/DIGEST.md"
  out="$(AGENT_NOTEPAD_NO_PULL=1 _run_hook "$np")"
  assert_contains "$out" "NOTES_SENTINEL_ARBBOT" "NOTES injected even when DIGEST absent"
  assert_not_contains "$out" "DIGEST_SENTINEL" "no stale digest content"
  # still valid JSON
  assert_eq "SessionStart" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" \
    "valid dual-field JSON without DIGEST"
  rm -rf "$(dirname "$np")"
}

test_outside_notepad_emits_empty_object() {
  local sb out; sb="$(mktemp -d)"
  out="$(AGENT_NOTEPAD_NO_PULL=1 _run_hook "$sb")"
  assert_eq "{}" "$(printf '%s' "$out" | jq -c '.')" "emits {} outside a notepad"
  rm -rf "$sb"
}

test_exit_code_zero_both_paths() {
  local np sb; np="$(_scaffold)"; sb="$(mktemp -d)"
  AGENT_NOTEPAD_NO_PULL=1 _run_hook "$np" >/dev/null
  assert_eq "0" "$?" "exit 0 inside a notepad"
  AGENT_NOTEPAD_NO_PULL=1 _run_hook "$sb" >/dev/null
  assert_eq "0" "$?" "exit 0 outside a notepad"
  rm -rf "$(dirname "$np")" "$sb"
}

test_pull_path_nonblocking_on_temp_git_repo() {
  # A temp git repo with NO remote: the pull path runs but returns instantly.
  # Proves the pull branch is exercised without blocking and the hook still injects.
  local np out; np="$(_scaffold)"
  git -C "$np" init -q 2>/dev/null || true
  git -C "$np" config user.email t@t 2>/dev/null || true
  git -C "$np" config user.name t 2>/dev/null || true
  git -C "$np" add -A 2>/dev/null || true
  git -C "$np" commit -qm init 2>/dev/null || true
  out="$(AGENT_NOTEPAD_PULL_TIMEOUT=2 _run_hook "$np")"
  assert_contains "$out" "NOTES_SENTINEL_ARBBOT" "injects with pull path enabled (no remote)"
  rm -rf "$(dirname "$np")"
}

test_completes_fast() {
  local np start end elapsed; np="$(_scaffold)"
  start="$(date +%s)"
  AGENT_NOTEPAD_NO_PULL=1 _run_hook "$np" >/dev/null
  end="$(date +%s)"
  elapsed=$(( end - start ))
  assert_le "$elapsed" "3" "SessionStart completes within 3s budget"
  rm -rf "$(dirname "$np")"
}

run_tests
