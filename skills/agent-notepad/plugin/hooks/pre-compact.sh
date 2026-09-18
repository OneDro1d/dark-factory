#!/usr/bin/env bash
# hooks/pre-compact.sh — PreCompact deterministic floor (DESIGN §7.5).
# Before context is compacted/cleared, snapshot recent user-intent + files-touched
# from the transcript, REDACT secrets, and persist so the next session rehydrates:
#   - inside a notepad → write the floor to <notepad>/PRECOMPACT.md (restored FIRST by
#     session-start.sh on source=compact) AND append a `precompact` milestone entry to the
#     session journal;
#   - outside a notepad → handoff-auto parity: write the snapshot to
#     <cwd>/.claude/handoff/handoff-latest.md (best-effort).
# Never blocks compaction. Emits {} on stdout (valid JSON). EXIT 0 ALWAYS.
set -u
_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/notepad.sh
. "$_DIR/../lib/notepad.sh"
# shellcheck source=../lib/snapshot.sh
. "$_DIR/../lib/snapshot.sh"

done_ok() { printf '{}\n'; exit 0; }

input="$(cat)"
tp="$(printf '%s' "$input"  | jq -r '.transcript_path // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)"
trig="$(printf '%s' "$input" | jq -r '.trigger // "auto"' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

snap="$(extract_snapshot "$tp")"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

np="$(find_notepad "$cwd" 2>/dev/null || true)"

if [ -n "$np" ]; then
  # ── 1) write the floor to PRECOMPACT.md — its OWN file, restored FIRST ──────
  # ⛔ MOVED 2026-09-18. The floor used to be APPENDED to the NOTES.md tail, and the restore
  # emits NOTES.md last and cuts it from the END to fit the ~10 KiB harness cap: the one block
  # written specifically for the post-compaction session was the block that restore dropped.
  # Measured on HoP: NOTES.md 14,008 bytes, ~1,200 restored, so the floor never arrived.
  # session-start.sh (source=compact) now emits PRECOMPACT.md first, ahead of the handoff.
  # Overwritten each time: it is the latest floor, not a history (that is the journal).
  floor="$np/PRECOMPACT.md"
  tmpf="$floor.tmp.$$"
  {
    printf '# PreCompact floor (deterministic, %s)\n' "$now"
    printf '_Auto-written by agent-notepad before compaction (trigger=%s, session=%s): what the\n' "$trig" "$sid"
    printf 'transcript showed just before it was summarised. Redacted, bounded. The handoff and NOTES.md\n'
    printf 'are the authority; this is the mechanical safety net under them._\n\n'
    printf '%s\n' "$snap"
  } > "$tmpf" 2>/dev/null && mv "$tmpf" "$floor" 2>/dev/null || rm -f "$tmpf" 2>/dev/null

  # One-time migration: strip a legacy floor block from the NOTES.md tail, so it stops costing
  # restore budget and cannot contradict the new file.
  notes="$np/NOTES.md"
  begin='<!-- pc-floor:start -->'
  end='<!-- pc-floor:end -->'
  if [ -f "$notes" ] && grep -qF "$begin" "$notes" 2>/dev/null; then
    tmp="$notes.tmp.$$"
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1} skip==1 {if($0==e) skip=0; next} {print}
    ' "$notes" > "$tmp" 2>/dev/null && mv "$tmp" "$notes" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi

  # ── 2) append a precompact milestone to the session journal (append-only) ──
  jf=""
  jf="$(ls -1t "$np/sessions/"*.jsonl 2>/dev/null | head -1)"
  if [ -z "$jf" ]; then
    jf="$(new_journal_file "$np" "$sid")"
  fi
  text="$(printf 'PreCompact floor written (trigger=%s)' "$trig")"
  line="$(jq -nc --arg ts "$now" --arg t "$text" --arg s "$sid" \
    '{ts:$ts, kind:"milestone", text:("precompact: " + $t), refs:[], commit:null, session:$s}' 2>/dev/null)"
  [ -z "$line" ] && line="{\"ts\":\"$now\",\"kind\":\"milestone\",\"text\":\"precompact floor\",\"refs\":[],\"commit\":null,\"session\":\"$sid\"}"
  append_journal "$jf" "$line"
else
  # ── outside a notepad: handoff-auto parity (best-effort, non-fatal) ─────────
  hdir="$cwd/.claude/handoff"
  hf="$hdir/handoff-latest.md"
  mkdir -p "$hdir" 2>/dev/null || true
  if should_flush "$hf" "$tp"; then
    tmp="$hf.tmp.$$"
    {
      printf '<!-- handoff session=%s trigger=%s source=deterministic -->\n' "$sid" "$trig"
      printf '## Handoff snapshot (deterministic floor)\n\n%s\n' "$snap"
    } > "$tmp" 2>/dev/null
    mv "$tmp" "$hf" 2>/dev/null || true
  fi
fi

done_ok
