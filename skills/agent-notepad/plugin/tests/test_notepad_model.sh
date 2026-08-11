#!/usr/bin/env bash
# U1 — Notepad model + template test.
# Scaffolds a temp notepad from notepad-template/, asserts the required files
# exist (per DESIGN §5–§6), then exercises lib/notepad.sh helpers
# (find_notepad, new_journal_file, append_journal) on the temp copy.
# TEMP-ONLY: never touches a real notepad, ~/.claude, or the live palace.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
TEMPLATE="$ROOT/notepad-template"
. "$HERE/assert.sh"
. "$ROOT/lib/notepad.sh"

# scaffold a temp notepad by copying the template (mktemp -d)
_scaffold() { # prints notepad root
  local base name np
  base="$(mktemp -d)"
  name="proj-arbbot"
  np="$base/$name"
  mkdir -p "$np"
  # copy template incl. dotfiles
  cp -R "$TEMPLATE/." "$np/"
  printf '%s' "$np"
}

test_template_dir_present() {
  assert_dir_exists "$TEMPLATE" "notepad-template/ exists"
}

test_required_files_exist() {
  local np; np="$(_scaffold)"
  assert_file_exists "$np/CLAUDE.md" "CLAUDE.md scaffolded"
  assert_file_exists "$np/NOTES.md" "NOTES.md scaffolded"
  assert_file_exists "$np/SCOPE.md" "SCOPE.md scaffolded"
  assert_file_exists "$np/.gitignore" ".gitignore scaffolded"
  assert_file_exists "$np/repos.manifest.json" "repos.manifest.json scaffolded"
  assert_file_exists "$np/org-routing.example.json" "org-routing.example.json scaffolded"
  assert_file_exists "$np/sessions/index.json" "sessions/index.json scaffolded"
  assert_file_exists "$np/.claude/settings.json" ".claude/settings.json scaffolded"
  rm -rf "$(dirname "$np")"
}

test_notes_has_seven_sections() {
  local np body; np="$(_scaffold)"; body="$(cat "$np/NOTES.md")"
  assert_contains "$body" "Current goal" "NOTES §Current goal"
  assert_contains "$body" "Repos in scope" "NOTES §Repos in scope"
  assert_contains "$body" "Last decisions" "NOTES §Last decisions"
  assert_contains "$body" "Next action" "NOTES §Next action"
  assert_contains "$body" "Open threads" "NOTES §Open threads"
  assert_contains "$body" "Key refs" "NOTES §Key refs"
  assert_contains "$body" "Blockers" "NOTES §Blockers"
  rm -rf "$(dirname "$np")"
}

test_gitignore_ignores_digest() {
  local np; np="$(_scaffold)"
  assert_contains "$(cat "$np/.gitignore")" "DIGEST.md" ".gitignore lists DIGEST.md"
  rm -rf "$(dirname "$np")"
}

test_manifest_valid_json_with_schema() {
  local np; np="$(_scaffold)"
  jq -e '.repos and (.requires_df_context_store != null)' "$np/repos.manifest.json" >/dev/null
  assert_eq "0" "$?" "repos.manifest.json is valid JSON with expected keys"
  rm -rf "$(dirname "$np")"
}

test_index_json_is_empty_array() {
  local np; np="$(_scaffold)"
  assert_eq "[]" "$(jq -c '.' "$np/sessions/index.json")" "sessions/index.json is []"
  rm -rf "$(dirname "$np")"
}

test_find_notepad_resolves_from_root_and_subdir() {
  local np; np="$(_scaffold)"
  assert_eq "$np" "$(find_notepad "$np")" "find_notepad resolves at root"
  assert_eq "$np" "$(find_notepad "$np/sessions")" "find_notepad walks up from subdir"
  rm -rf "$(dirname "$np")"
}

test_find_notepad_empty_outside_notepad() {
  local sb; sb="$(mktemp -d)"
  assert_eq "" "$(find_notepad "$sb")" "find_notepad prints nothing outside a notepad"
  rm -rf "$sb"
}

test_new_journal_file_creates_jsonl() {
  local np jf; np="$(_scaffold)"
  jf="$(new_journal_file "$np")"
  assert_file_exists "$jf" "new_journal_file created a file"
  assert_contains "$jf" "/sessions/" "journal file lives under sessions/"
  assert_contains "$jf" ".jsonl" "journal file is .jsonl"
  rm -rf "$(dirname "$np")"
}

test_append_journal_writes_line() {
  local np jf line n; np="$(_scaffold)"
  jf="$(new_journal_file "$np")"
  append_journal "$jf" '{"ts":"2026-07-10T00:00:00Z","kind":"note","text":"hello","refs":[],"commit":null,"session":"s1"}'
  assert_file_exists "$jf" "journal file present after append"
  n="$(wc -l < "$jf" | tr -d ' ')"
  assert_eq "1" "$n" "one line appended"
  assert_eq "hello" "$(jq -r '.text' "$jf")" "appended line is valid JSONL with text"
  # a second append accumulates (append-only)
  append_journal "$jf" '{"ts":"2026-07-10T00:01:00Z","kind":"decision","text":"world","refs":[],"commit":null,"session":"s1"}'
  n="$(wc -l < "$jf" | tr -d ' ')"
  assert_eq "2" "$n" "second line appended (append-only)"
  rm -rf "$(dirname "$np")"
}

run_tests
