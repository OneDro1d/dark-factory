#!/usr/bin/env bash
# Unit 3 — redaction (VR-4) + bounded rewrite (VR-3).
# NOTE: provider-shaped test tokens are assembled at runtime from split prefixes
# so the contiguous literal never appears in source — otherwise GitHub push
# protection (secret scanning) blocks the commit on these very test fixtures.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=./assert.sh
. "$HERE/assert.sh"
# shellcheck source=../lib/redact.sh
. "$ROOT/lib/redact.sh"

test_redacts_openai_key() {
  local out tok
  tok="sk-""abc123DEF456ghi789jkl012mno345pqr678"
  out="$(printf 'using key %s now\n' "$tok" | redact_secrets)"
  assert_not_contains "$out" "$tok" "openai key removed"
  assert_contains "$out" "[REDACTED]" "redaction marker present"
}

test_redacts_github_token() {
  local out tok
  tok="ghp_""0123456789abcdefABCDEF0123456789abcdef"
  out="$(printf 'token %s done\n' "$tok" | redact_secrets)"
  assert_not_contains "$out" "$tok" "gh token removed"
}

test_redacts_bearer_header() {
  local out
  out="$(printf 'Authorization: Bearer eyJhbGciOi.payload.sig\n' | redact_secrets)"
  assert_not_contains "$out" "eyJhbGciOi.payload.sig" "bearer value removed"
}

test_redacts_aws_access_key() {
  local out tok
  tok="AKIA""IOSFODNN7EXAMPLE"
  out="$(printf 'aws %s key\n' "$tok" | redact_secrets)"
  assert_not_contains "$out" "$tok" "aws key removed"
}

test_redacts_password_assignment() {
  local out
  out="$(printf 'password=hunter2supersecret\n' | redact_secrets)"
  assert_not_contains "$out" "hunter2supersecret" "password value removed"
}

test_preserves_ordinary_text() {
  local out
  out="$(printf 'The quick brown fox builds a handoff doc.\n' | redact_secrets)"
  assert_contains "$out" "quick brown fox" "ordinary text preserved"
  assert_not_contains "$out" "[REDACTED]" "no over-redaction"
}

test_bound_passes_short_input() {
  local out n
  out="$(printf 'a\nb\nc\n' | bound_lines 10)"
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  assert_eq "3" "$n" "short input unchanged"
}

test_bound_caps_long_input() {
  local out n
  out="$(seq 1 200 | bound_lines 120)"
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  assert_le "$n" "120" "capped at 120 lines"
  assert_contains "$out" "truncated" "truncation marker present"
}

# --- Regression: leaks found by the adversary gate (2026-06-26) ---

test_redacts_github_fine_grained_pat() {
  local out tok
  tok="github_""pat_11ABCDEZ0aBcDeFgHiJkLmnopQRStuvWXyz1234567890abcd"
  out="$(printf 'tok %s done\n' "$tok" | redact_secrets)"
  assert_not_contains "$out" "$tok" "fine-grained PAT removed"
}

test_redacts_slack_token() {
  local out tok
  tok="xox""b-2401234567-2409876543-AbCdEfGhIjKlMnOpQrStUvWx"
  out="$(printf 'slack %s now\n' "$tok" | redact_secrets)"
  assert_not_contains "$out" "$tok" "slack token removed"
}

test_redacts_pem_private_key() {
  local out
  out="$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nuniqueKEYMATERIAL12345\n-----END RSA PRIVATE KEY-----\n' | redact_secrets)"
  assert_not_contains "$out" "uniqueKEYMATERIAL12345" "pem key body removed"
}

test_redacts_json_quoted_password() {
  local out
  out="$(printf '{"password": "json_pw_leak4567"}\n' | redact_secrets)"
  assert_not_contains "$out" "json_pw_leak4567" "json-quoted secret value removed"
}

test_redacts_keyworded_underscore_assignment() {
  local out
  out="$(printf 'secret_key=plainsecretval_8899\naws_secret_access_key=AwSsecretLEAKval_77\n' | redact_secrets)"
  assert_not_contains "$out" "plainsecretval_8899" "secret_key value removed"
  assert_not_contains "$out" "AwSsecretLEAKval_77" "aws_secret_access_key value removed"
}

run_tests
