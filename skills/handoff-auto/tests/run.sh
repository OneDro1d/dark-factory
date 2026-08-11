#!/usr/bin/env bash
# Run the whole handoff suite; non-zero exit if any file fails.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
for t in test_redact test_pre_compact test_session_start test_user_prompt test_integration; do
  printf '\n=== %s ===\n' "$t"
  bash "$HERE/$t.sh" || fail=1
done
printf '\n=== suite %s ===\n' "$([ "$fail" -eq 0 ] && echo PASS || echo FAIL)"
exit "$fail"
