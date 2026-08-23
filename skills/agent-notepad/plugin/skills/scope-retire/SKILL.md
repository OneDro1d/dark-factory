---
name: scope-retire
description: 'Archive a completed or abandoned agent-notepad while keeping its journal history intact. Marks the notepad retired (SCOPE.md status + a final journal milestone), stops it from auto-loading and syncing on future sessions, and preserves the append-only sessions/ history and handoffs for later recall — it never deletes the journal, the memory index entries, or the remote. Reversible: a later scope-init re-activates it. Use when an objective is done, a scope is being wound down, or a notepad should be shelved. Triggers on "scope-retire", "retire this scope", "archive the notepad", "close out this objective", "wind down the scope".'
---

# scope-retire — archive a notepad, keep the history

Retiring a notepad means "stop treating this as an active objective" — **not** "delete it".
The journal (`sessions/*.jsonl`), the handoffs, the memory-index (`wing=<prefix>`) entries,
and the git remote all stay. Retirement is a reversible status change plus a clean final
snapshot. See `../../DESIGN.md` (§6 file contracts, §16 acceptance).

**Never destructive.** This skill does not `rm` journals, does not empty the memory index,
does not delete the GitHub repo, and does not force-push over history. If the operator wants
hard deletion, that is a separate manual action they perform themselves — surface it, don't
do it.

---

## Procedure

### 1. Confirm the notepad and its state

- Resolve the notepad directory (cwd or the operator-named scope). Confirm it *is* a
  notepad (has SCOPE.md + repos.manifest.json + sessions/).
- Read SCOPE.md done-criteria and report which are met vs open, so the operator retires
  with eyes open. Retiring with open criteria is allowed (abandonment) — just say so.

### 2. Write a final snapshot into NOTES.md

Do one last rewrite of `NOTES.md` (§6.1): set Current goal to a one-line outcome
("Retired <date>: <done | abandoned because …>"), Next action to "none — scope retired",
and leave the Key refs / Blockers as the honest final state. This is the summary a future
reader lands on first; keep it terse and un-redacted of caveats.

### 3. Append a retirement milestone to the journal (do NOT rewrite history)

Append **one** new event to the current session journal
(`sessions/<ISO8601>_<id>.jsonl`) — never edit or delete existing lines:

```
{"ts":"<now>","kind":"milestone","text":"scope retired: <outcome>","refs":[],"commit":null,"session":"<id>"}
```

The append-only journal is the history of record; retirement adds a closing entry, it does
not erase what came before.

### 4. Mark SCOPE.md retired

Add a status line at the top of SCOPE.md, e.g.
`> **Status:** RETIRED <date> — <one-line outcome>`. This is the durable, human-visible
flag that the notepad is shelved. Leave Objective + Done-criteria in place for the record.

### 5. Disarm auto-load / auto-sync for future sessions

So a stray future session in this directory doesn't resurrect it as "active":
- In the notepad's `.claude/settings.json`, the read/sync hooks key off notepad detection;
  a RETIRED SCOPE.md is the signal the SessionStart hook should treat as "inject the final
  NOTES.md snapshot read-only, skip the digest rebuild and best-effort push". Record the
  retired status where the hook can see it (SCOPE.md status line is the source of truth).
- Do not remove the hooks or the settings file — retirement is reversible.

### 6. Final sync, then leave the remote alone

If a remote exists, do one best-effort `git -C <notepad> add -A && commit && push` of the
retirement snapshot (final NOTES.md, journal milestone, SCOPE status) so the archived state
is durable off-machine. **Then stop** — do not delete the remote branch or repo. Preserve
`handoffs/` as-is.

---

## Done when

SCOPE.md shows RETIRED with an outcome, NOTES.md holds the final snapshot, the journal has
its closing milestone appended (nothing removed), future sessions won't treat it as active,
and — if there's a remote — the archived state is pushed. Report: the notepad path, the
outcome (done vs abandoned + which done-criteria were open), and that history was preserved
(journal + handoffs + memory index untouched).

## Guardrails

- Journal is append-only: add the milestone, never edit or delete prior lines.
- No destructive ops: no journal deletion, no memory-index purge, no repo/remote deletion,
  no force-push. Hard deletion is the operator's own manual call.
- Reversible: a later `scope-init` on the same directory re-activates the notepad.
