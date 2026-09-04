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

# ⛔ THE ENCODE-FAILURE BRANCH MUST ITSELF BE EXERCISED.
#
# The whole lesson of the argv bug is that a hook which exits 0 has exactly one channel to the
# session — its payload — so a failure that emits nothing is invisible. The fix added a branch
# that emits a WARNING instead. An UNTESTED fallback is the same defect one level down: it
# would be discovered only by the failure it exists to report.
#
# jq is stubbed to fail ONLY on the slurp form, leaving the short fixed-size `--arg` call in
# the fallback working — which is the realistic shape (that call is bounded and cannot hit the
# ceiling). PATH is prepended for this one invocation only.
test_encode_failure_warns_instead_of_emitting_nothing() {
  local np out stub; np="$(_scaffold)"
  stub="$(mktemp -d)"
  cat > "$stub/jq" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "-Rs" ]; then
    echo "stub: simulated encode failure" >&2
    exit 5
  fi
done
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/local/bin jq "$@"
STUB
  chmod +x "$stub/jq"

  out="$(PATH="$stub:$PATH" AGENT_NOTEPAD_NO_PULL=1 _run_hook "$np")"

  # ⚠️ NOT NOTHING. This is the assertion the original bug would have failed.
  if [ -n "$out" ]; then _pass; else _fail "encode failure still emits a payload"; fi
  ASSERT_CASES=$((ASSERT_CASES + 1))

  assert_contains "$out" "FAILED TO ENCODE" "the failure is NAMED in the payload"
  assert_contains "$out" "$np/NOTES.md" "and it names the file the reader must open"
  # ⚠️ Must still be a parseable hook payload: a malformed one is discarded whole, which
  # would put us straight back to injecting nothing.
  assert_eq "SessionStart" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" \
    "the warning is still valid dual-field SessionStart JSON"

  rm -rf "$stub" "$(dirname "$np")"
}

# ⛔ THE REGRESSION TEST THIS SUITE DID NOT HAVE, AND THE REASON THE BUG SHIPPED.
#
# Every case above uses a sentinel notepad of a few hundred bytes. The hook encoded its
# payload with `jq -n --arg ctx "$combined"` — an ARGV element — and Linux caps one argv
# element at 128 KB (MAX_ARG_STRLEN). So on every Coder box in the fleet jq died with
# "Argument list too long", the hook still exited 0, and ZERO context was injected while
# the suite stayed green: the fixture was three orders of magnitude below the ceiling.
#
# ⚠️ The defect was in a DIMENSION the tests never varied. Correctness was asserted; SIZE
# was not, so the one property that mattered had no coverage at any point in the suite.
#
# 1.5 MB is chosen to exceed BOTH ceilings — Linux's 128 KB per-argument cap and macOS's
# ~1 MB total execve limit — so this test fails against the old code on the maintainer's
# own laptop, not only on the machine that happened to report the bug. A test that can
# only fail on a platform nobody develops on is not a regression test.
test_payload_larger_than_argv_limit_still_restores() {
  local np out big
  np="$(_scaffold)"
  # ~1.5 MB of filler, then the sentinel LAST so a truncating encoder cannot pass.
  big="$(mktemp)"
  awk 'BEGIN{ for(i=0;i<24000;i++) print "notes filler line to exceed the argv ceiling ......" }' > "$big"
  cat "$big" >> "$np/NOTES.md"
  printf '\nBIG_NOTES_TAIL_SENTINEL\n' >> "$np/NOTES.md"
  rm -f "$big"

  out="$(AGENT_NOTEPAD_NO_PULL=1 _run_hook "$np")"

  # The tail proves the WHOLE payload survived, not merely that something was emitted.
  assert_contains "$out" "BIG_NOTES_TAIL_SENTINEL" \
    "a NOTES.md past the argv ceiling is injected whole (tail present)"
  assert_contains "$out" "NOTES_SENTINEL_ARBBOT" \
    "the head of an oversized NOTES.md survives too"
  assert_eq "SessionStart" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" \
    "oversized payload is still valid dual-field JSON"

  # ⚠️ And it must not have degraded to the encode-failure branch. That branch is correct
  # behaviour for a genuine failure and a FALSE PASS here: it emits valid JSON carrying a
  # warning, so every assertion above except the sentinels would still hold.
  assert_not_contains "$out" "FAILED TO ENCODE" \
    "the oversized payload took the real path, not the encode-failure fallback"

  rm -rf "$(dirname "$np")"
}

# ⛔ THE REGRESSION THAT REACHED A REAL OPERATOR. The hook emitted the handoff's NAME plus
# "read it IF NOTES.md does not already cover where the work stands". On a real /clear the
# session read a complete-looking NOTES.md, resolved that condition as covered, never opened
# the handoff, and told the operator "session start auto-loads NOTES.md, not the handoff file."
#
# ⚠️ A NAME IN THE PAYLOAD IS NOT DELIVERY, and the suite could not tell the difference because
# nothing asserted on the handoff's CONTENT. Asserting the filename appeared would have PASSED
# against the broken hook — the filename is precisely what it emitted.
test_newest_handoff_content_is_injected_not_just_named() {
  local np out; np="$(_scaffold)"
  mkdir -p "$np/handoffs"
  printf '# older handoff\nOLD_HANDOFF_SENTINEL should not be chosen\n' > "$np/handoffs/2026-01-01-older.md"
  printf '# Handoff: the current mission\nHANDOFF_BODY_SENTINEL the one next action\n' > "$np/handoffs/2026-02-02-newest.md"
  touch -t 202601010000 "$np/handoffs/2026-01-01-older.md"
  touch -t 202602020000 "$np/handoffs/2026-02-02-newest.md"

  out="$(AGENT_NOTEPAD_NO_PULL=1 _run_hook "$np")"

  assert_contains "$out" "HANDOFF_BODY_SENTINEL" \
    "the newest handoff's CONTENT is injected, not merely named"
  assert_not_contains "$out" "OLD_HANDOFF_SENTINEL" "only the NEWEST handoff is injected"
  # ⚠️ The instruction must not be CONDITIONAL — the conditional is what a cold reader
  # resolved as "covered". It has to outrank the Notes explicitly.
  assert_contains "$out" "READ THIS FIRST" "the handoff is presented imperatively"
  assert_eq "SessionStart" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" \
    "still valid dual-field JSON with a handoff attached"
  rm -rf "$(dirname "$np")"
}

# ⚠️ PRECEDENCE IS A FACT ABOUT TIMESTAMPS, NOT A CONSTANT. The first version of the fix said
# the handoff always WINS. Correct when it is the later document, WRONG when the Notes moved on
# since — which would trade "handoff never read" for "stale handoff overrides current Notes".
# Both directions are asserted because a rule that is right half the time reads as right.
test_handoff_precedence_follows_the_timestamps() {
  local np out; np="$(_scaffold)"
  mkdir -p "$np/handoffs"
  printf '# Handoff\nPRECEDENCE_SENTINEL\n' > "$np/handoffs/2026-05-05-h.md"

  # handoff NEWER than the notes
  touch -t 202601010000 "$np/NOTES.md"
  touch -t 202602020000 "$np/handoffs/2026-05-05-h.md"
  out="$(AGENT_NOTEPAD_NO_PULL=1 _run_hook "$np")"
  assert_contains "$out" "HANDOFF IS NEWER" "says the handoff wins when it is newer"
  assert_not_contains "$out" "are NEWER than this handoff" "does not also claim the reverse"

  # notes NEWER than the handoff
  touch -t 202603030000 "$np/NOTES.md"
  out="$(AGENT_NOTEPAD_NO_PULL=1 _run_hook "$np")"
  assert_contains "$out" "are NEWER than this handoff" "says the Notes lead when they are newer"
  assert_not_contains "$out" "HANDOFF IS NEWER" "does not also claim the reverse"
  # ...and the handoff is STILL injected either way — precedence is not suppression.
  assert_contains "$out" "PRECEDENCE_SENTINEL" "the handoff is injected even when the Notes lead"
  rm -rf "$(dirname "$np")"
}

# A truncated handoff must never be mistakable for a whole one.
test_oversized_handoff_announces_its_truncation() {
  local np out; np="$(_scaffold)"
  mkdir -p "$np/handoffs"
  { printf '# Handoff\nHANDOFF_HEAD_SENTINEL\n'
    awk 'BEGIN{ for(i=0;i<400;i++) print "filler line to exceed the handoff cap ......" }'
    printf 'HANDOFF_TAIL_SENTINEL\n'; } > "$np/handoffs/2026-03-03-big.md"

  out="$(AGENT_NOTEPAD_HANDOFF_MAX_BYTES=2048 AGENT_NOTEPAD_NO_PULL=1 _run_hook "$np")"

  assert_contains "$out" "HANDOFF_HEAD_SENTINEL" "the head of a capped handoff still arrives"
  assert_contains "$out" "TRUNCATED" "truncation is ANNOUNCED, never silent"
  assert_not_contains "$out" "HANDOFF_TAIL_SENTINEL" "the cap actually bit"
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
