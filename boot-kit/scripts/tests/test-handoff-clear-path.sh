#!/usr/bin/env bash
# test-handoff-clear.sh -- the SessionStart loader must point at the deliberate handoff on
# EVERY cold path, not only after compaction.
#
# The gap: /clear fires no PreCompact, so no ~/.claude/handoffs/<sid>.md snapshot is ever
# written, and the loader used to return early with nothing emitted. These cases fail
# against that version and pass against the snapshot-independent one.
set -uo pipefail

# ⚠️ THREE levels up, not one. This suite lives in boot-kit/scripts/tests/ and the hook
# lives at the REPO ROOT in hooks/. The first version said ../hooks, which resolves to
# boot-kit/hooks -- a directory that does not exist -- so every case failed in CI while
# passing locally, because locally HOOK= was always passed explicitly.
SELF="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK:-$SELF/../../../hooks/handoff-sessionstart-load.py}"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A fake notepad: NOTES.md marks the root, handoffs/ holds the deliberate docs.
NP="$TMP/notepad"
mkdir -p "$NP/handoffs/nested/deep"
printf '# NOTES\n' > "$NP/NOTES.md"
printf 'older\n'  > "$NP/handoffs/2026-01-01-old.md"
sleep 1
printf 'newest\n' > "$NP/handoffs/2026-09-01-current.md"

# HOME is redirected so a real ~/.claude/handoffs snapshot cannot mask the fallback.
run() { # run <source> <cwd> [session_id]
  printf '{"session_id":"%s","source":"%s","cwd":"%s"}' \
    "${3:-test-sid-none}" "$1" "$2" | HOME="$TMP/home" python3 "$HOOK" 2>/dev/null
}
mkdir -p "$TMP/home/.claude/handoffs"

# --- 1. the gap itself: /clear with no snapshot must still point at the handoff ---
OUT="$(run clear "$NP")"
if printf '%s' "$OUT" | grep -q '2026-09-01-current.md'; then
  ok "clear with no snapshot names the newest handoff"
else
  bad "clear with no snapshot names the newest handoff" "got: ${OUT:0:200}"
fi

# --- 2. it must pick the NEWEST, not just any ---
if printf '%s' "$OUT" | grep -q '2026-01-01-old.md'; then
  bad "clear names the newest, not the oldest" "named the old one"
else
  ok "clear names the newest, not the oldest"
fi

# --- 3. both output fields are populated (the 2026-06-26 belt-and-suspenders finding) ---
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("systemMessage") and d["hookSpecificOutput"]["additionalContext"] else 1)'; then
  ok "emits both systemMessage and additionalContext"
else
  bad "emits both systemMessage and additionalContext" "got: ${OUT:0:200}"
fi

# --- 4. it POINTS, it does not COPY: the handoff body must not be inlined ---
if printf '%s' "$OUT" | grep -q 'newest'; then
  bad "points without copying the handoff body" "inlined the file contents"
else
  ok "points without copying the handoff body"
fi

# --- 5. resolves the notepad from a DEEP cwd, not just its root ---
OUT_DEEP="$(run clear "$NP/handoffs/nested/deep")"
if printf '%s' "$OUT_DEEP" | grep -q '2026-09-01-current.md'; then
  ok "walks up from a nested cwd to the notepad root"
else
  bad "walks up from a nested cwd to the notepad root" "got: ${OUT_DEEP:0:200}"
fi

# --- 6. startup (a cold window) also gets the pointer ---
if printf '%s' "$(run startup "$NP")" | grep -q '2026-09-01-current.md'; then
  ok "startup gets the pointer"
else
  bad "startup gets the pointer" "emitted nothing"
fi

# --- 7. resume does NOT: the context is intact, a pointer is noise ---
if [ -z "$(run resume "$NP")" ]; then
  ok "resume is silent (context intact)"
else
  bad "resume is silent (context intact)" "emitted a pointer anyway"
fi

# --- 8. outside a notepad: silent, this hook has no business there ---
mkdir -p "$TMP/not-a-notepad"
if [ -z "$(run clear "$TMP/not-a-notepad")" ]; then
  ok "silent outside a notepad"
else
  bad "silent outside a notepad" "emitted something"
fi

# --- 9. notepad with NO handoffs on clear: names the gap rather than staying quiet ---
NP2="$TMP/empty-notepad"
mkdir -p "$NP2/handoffs"
printf '# NOTES\n' > "$NP2/NOTES.md"
if printf '%s' "$(run clear "$NP2")" | grep -qi 'gap'; then
  ok "empty handoffs/ on clear reports the gap"
else
  bad "empty handoffs/ on clear reports the gap" "stayed silent"
fi

# --- 10. ...but a plain startup in a fresh notepad is NOT a gap ---
if [ -z "$(run startup "$NP2")" ]; then
  ok "empty handoffs/ on startup is silent (a new notepad legitimately has none)"
else
  bad "empty handoffs/ on startup is silent" "cried gap on a new notepad"
fi

# --- 11. REGRESSION: the snapshot path still wins when a snapshot applies ---
SID="test-sid-snap"
printf '# Pre-compaction handoff snapshot\nSNAPSHOT-MARKER\n' \
  > "$TMP/home/.claude/handoffs/$SID.md"
OUT_SNAP="$(run compact "$NP" "$SID")"
if printf '%s' "$OUT_SNAP" | grep -q 'SNAPSHOT-MARKER'; then
  ok "snapshot still takes priority on compact"
else
  bad "snapshot still takes priority on compact" "got: ${OUT_SNAP:0:200}"
fi

# --- 12. REGRESSION: consume-once still renames the snapshot ---
if [ -f "$TMP/home/.claude/handoffs/$SID.md.loaded" ]; then
  ok "snapshot is consumed once (renamed to .loaded)"
else
  bad "snapshot is consumed once (renamed to .loaded)" "not renamed"
fi

# --- 13. after consumption, a second compact falls through to the pointer ---
if printf '%s' "$(run compact "$NP" "$SID")" | grep -q '2026-09-01-current.md'; then
  ok "consumed snapshot falls through to the handoff pointer"
else
  bad "consumed snapshot falls through to the handoff pointer" "emitted nothing"
fi

# --- 14. malformed stdin must not raise ---
if printf 'not json' | HOME="$TMP/home" python3 "$HOOK" >/dev/null 2>&1; then
  ok "malformed stdin exits cleanly"
else
  bad "malformed stdin exits cleanly" "non-zero exit"
fi

# --- 15. missing cwd key must not raise (falls back to os.getcwd) ---
if printf '{"session_id":"x","source":"clear"}' | HOME="$TMP/home" python3 "$HOOK" >/dev/null 2>&1; then
  ok "missing cwd exits cleanly"
else
  bad "missing cwd exits cleanly" "non-zero exit"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
printf 'ASSERTIONS: %s\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
