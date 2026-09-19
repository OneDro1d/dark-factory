#!/usr/bin/env bash
# Session journals must never carry a credential.
#
# ⛔ WHY (2026-09): sessions/*.jsonl is committed and pushed in every notepad, and the Stop hook
# journaled raw Bash command text with no redaction at all. A credential typed into a command
# reached a committed journal. Two defects, both pinned:
#   1. hooks/stop.sh never called redact_secrets (only snapshot.sh and publish-handoff.sh did);
#   2. lib/redact.sh had no rule for syn_ tokens, *_PAT/*_TOKEN/*_KEY assignments or X-… headers,
#      so even a redacting caller passed `X-Pat:syn_…` and `<NAME>_PAT=syn_…` through.
#
# ⚠️ DUMMY VALUES ONLY: every "secret" here is zeros. Never put a real token in a test.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
HOOK="$ROOT/hooks/stop.sh"
. "$HERE/assert.sh"
. "$ROOT/lib/redact.sh"

Z32="00000000000000000000000000000000"
SYN="syn_$Z32"
Z12="000000000000"   # no legitimate journal field (timestamps, paths) carries twelve zeros in a row

_r() { printf '%s' "$1" | redact_secrets; }

# --- the redactor itself ------------------------------------------------------

test_redacts_synapse_token_forms() {
  assert_not_contains "$(_r "curl -H \"X-Pat:$SYN\" https://hub.example")" "$Z12" "X-Pat:syn_… header is redacted"
  assert_not_contains "$(_r "SYNAPSE_ONEDROID_PAT=$SYN claude -p hi")" "$Z12" "SYNAPSE_ONEDROID_PAT=syn_… is redacted"
  assert_not_contains "$(_r "curl --header $SYN https://hub.example")" "$Z12" "a bare syn_… token is redacted"
  assert_not_contains "$(_r "curl -H \"Authorization: Bearer $SYN\"")" "$Z12" "Bearer syn_… is still redacted"
}

test_redacts_keyworded_assignments() {
  assert_not_contains "$(_r "export GITHUB_TOKEN=${Z12}abc")" "$Z12" "*_TOKEN= assignment is redacted"
  assert_not_contains "$(_r "DO_API_KEY=${Z12} doctl apps list")" "$Z12" "*_KEY= assignment is redacted"
  assert_not_contains "$(_r "env MY_PAT='${Z12}' run")" "$Z12" "quoted *_PAT= assignment is redacted"
  assert_not_contains "$(_r "APP_SECRET=\"${Z12}\"")" "$Z12" "*_SECRET= assignment is redacted"
}

test_redacts_header_forms() {
  assert_not_contains "$(_r "curl -H 'X-Api-Key: ${Z12}'")" "$Z12" "X-Api-Key: header is redacted"
  assert_not_contains "$(_r "curl -H 'Authorization: Basic ${Z12}'")" "$Z12" "Authorization: Basic is redacted"
  assert_not_contains "$(_r "curl -H 'Authorization: token ${Z12}'")" "$Z12" "Authorization: token is redacted"
}

test_keeps_non_secrets() {
  # over-redaction destroys the journal's value; these must survive untouched
  local s
  s="git -C /abs/repo log -1 e52bf1b3333ee0cfa83101fca25a4e700ea64b40"
  assert_eq "$s" "$(_r "$s")" "a commit sha and a path are kept"
  s="PATH=/usr/local/bin:/usr/bin make test"
  assert_eq "$s" "$(_r "$s")" "PATH= is not a credential"
  s="python3 bin/gate-split.py 2026-09-18T21:41:52Z"
  assert_eq "$s" "$(_r "$s")" "an ordinary command is kept"
}

test_redaction_is_idempotent() {
  local once twice
  once="$(_r "SYNAPSE_ONEDROID_PAT=$SYN curl -H 'X-Pat:$SYN'")"
  twice="$(_r "$once")"
  assert_eq "$once" "$twice" "redacting twice changes nothing"
}

# --- the Stop hook end to end ------------------------------------------------

_scaffold_notepad() {
  local base np
  base="$(mktemp -d)"; np="$base/np"
  mkdir -p "$np/sessions"; : > "$np/NOTES.md"; printf '[]\n' > "$np/sessions/index.json"
  git -C "$np" init -q
  printf '%s' "$np"
}

_tool_use() { # name input-json
  jq -cn --arg n "$1" --argjson i "$2" '{type:"assistant",message:{content:[{type:"tool_use",name:$n,input:$i}]}}'
}

test_stop_hook_journal_carries_no_secret() {
  local np tp out jf body key
  np="$(_scaffold_notepad)"; tp="$np/transcript.jsonl"
  key="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n%s\n%s\n-----END OPENSSH PRIVATE KEY-----' "$Z32" "$Z32")"
  {
    printf '%s\n' '{"type":"user","message":{"content":"go"}}'
    _tool_use Bash "$(jq -cn --arg c "curl -H \"X-Pat:$SYN\" https://hub.example/mcp" '{command:$c}')"
    _tool_use Bash "$(jq -cn --arg c "SYNAPSE_ONEDROID_PAT=$SYN claude -p hello" '{command:$c}')"
    _tool_use Bash "$(jq -cn --arg c "curl --header $SYN https://hub.example" '{command:$c}')"
    _tool_use Bash "$(jq -cn --arg c "printf '%s' \"$key\" > /tmp/k" '{command:$c}')"
    _tool_use Bash "$(jq -cn --arg c "go build ./..." '{command:$c}')"
    _tool_use Write "$(jq -cn --arg f "/abs/code/alpha.go" '{file_path:$f}')"
  } > "$tp"

  out="$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"redact1"}' "$tp" "$np" | bash "$HOOK")"
  assert_eq "{}" "$out" "hook still prints {} (allow)"

  jf="$(ls "$np"/sessions/*.jsonl 2>/dev/null | head -1)"
  assert_file_exists "$jf" "a journal was written"
  body="$(cat "$jf" 2>/dev/null)"
  assert_not_contains "$body" "$Z12" "the journal carries no dummy secret value"
  assert_not_contains "$body" "syn_0" "the journal carries no syn_ token"
  assert_contains "$body" "go build ./..." "ordinary commands are still journaled"
  assert_contains "$body" "https://hub.example/mcp" "the non-secret part of a redacted command is kept"
  assert_contains "$body" "/abs/code/alpha.go" "file-touch entries are still journaled"
  assert_eq "" "$(jq -c 'select((.ts|not) or (.kind|not))' "$jf" 2>/dev/null)" "every journal line is still valid JSON"
  rm -rf "$(dirname "$np")"
}

run_tests
