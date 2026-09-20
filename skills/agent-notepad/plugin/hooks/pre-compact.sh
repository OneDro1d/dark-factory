#!/usr/bin/env bash
# hooks/pre-compact.sh — the deterministic floor (DESIGN §7.5). Wired on TWO events:
#   PreCompact                      — before the context is summarised
#   SessionEnd, matcher `clear`     — before the context is DISCARDED by /clear
#
# ⛔ THE SECOND WIRING IS THE POINT, AND IT WAS MISSING FOR MONTHS. This header always said
# "compacted/cleared", but nothing was ever wired on the clear path: PreCompact does not fire on
# /clear. So a compaction kept a floor and a /clear — the path the skill actively RECOMMENDS when
# the window fills — kept nothing. A file that describes an intention is not a wiring.
#
# ⚠️ KEEP THIS FILENAME even though it now serves both events. wire-settings.py keys a wired hook
# on `<file> --part <name>`, so renaming it would create a NEW key and leave the OLD entry wired
# forever on every machine that already installed it — the exact trap #212 records. An inaccurate
# name is the cheaper cost. Wiring is scoped per EVENT (wire-settings.py `wired_paths`), so the
# same file under SessionEnd does not collide with its PreCompact entry.
#
# ⚠️ MEASURED on Claude Code 2.1.278 (probes + controls in the M-KITOPT-20260920 mission dir):
#   - SessionEnd fires on /clear with reason=clear, and carries transcript_path.
#   - The transcript is COMPLETE at that moment (a marker planted in the session read back).
#   - It fires 20-29 ms BEFORE SessionStart(source=clear), sequentially.
#   - The default SessionEnd budget is ~1.5 s and KILLS a slower hook, so the wiring sets an
#     explicit `timeout`. extract_snapshot measured 0.32 s on a 12 MB transcript — it fits today
#     and grows with the transcript, which is why the timeout is explicit and not assumed.
#   ⚠️ The ordering and the completeness are NOT DOCUMENTED by the harness. They are readings of
#   one version, not guarantees. If the floor ever comes back empty, re-run the probes FIRST.
#
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
ev="$(printf '%s' "$input"  | jq -r '.hook_event_name // empty' 2>/dev/null)"
# PreCompact says `trigger` (auto|manual); SessionEnd says `reason` (clear|logout|…). One label.
trig="$(printf '%s' "$input" | jq -r '.trigger // .reason // "auto"' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

# ⛔ FAIL CLOSED ON A SESSIONEND THAT IS NOT A CLEAR — this guard is not redundant with the
# matcher, it is the reason the floor survives. MEASURED: a /clear emits
#   SessionEnd(clear) -> SessionStart(clear) -> [new session] -> SessionEnd(other)
# and that trailing `other` fires against a near-empty transcript. The floor is overwritten in
# place by design (it is the latest, not a history), so a SessionEnd wiring that does NOT filter
# writes a good floor and then destroys it ~900 ms later. `matcher: "clear"` does filter
# correctly — but the matcher lives in settings.json, which is merged ADD-ONLY and can be
# hand-edited, so a wiring that loses it must degrade to doing nothing rather than to eating the
# floor. A guard whose only job is to be redundant with a correct config is the one that pays
# for itself when the config is wrong.
# ⚠️ logout / prompt_input_exit are DELIBERATELY out of scope: the next session there is a
# `startup`, which already restores the handoff and NOTES.md from disk. The floor's unique value
# is the /clear case, where the transcript is discarded and NO summary is written in its place.
if [ "$ev" = "SessionEnd" ] && [ "$trig" != "clear" ]; then
  done_ok
fi

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
  # ⚠️ SAY WHICH EVENT WROTE IT AND WHAT HAPPENED TO THE CONTEXT. A floor restored after a
  # /clear and a floor restored after a compaction mean different things to the reader: after a
  # compaction a summary carries the orientation and this is a safety net under it; after a
  # /clear there IS no summary and this is the only record of what was in flight. A header that
  # says "before compaction" on both is actively misleading on the path that needs it most.
  if [ "$trig" = "clear" ]; then
    _what='before /clear DISCARDED the context'
    _detail='⛔ The context was CLEARED, not summarised — nothing else carries what was in flight.'
  else
    _what='before compaction'
    _detail='The summary above carries the orientation; this is the mechanical safety net under it.'
  fi
  {
    printf '# Session floor (deterministic, %s)\n' "$now"
    printf '_Auto-written by agent-notepad %s (event=%s, trigger=%s, session=%s):\n' "$_what" "${ev:-PreCompact}" "$trig" "$sid"
    printf 'what the transcript showed just before. Redacted, bounded. %s\n' "$_detail"
    printf 'The handoff and NOTES.md remain the authority._\n\n'
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
  text="$(printf 'floor written (event=%s, trigger=%s)' "${ev:-PreCompact}" "$trig")"
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
