---
name: handoff
description: Publish a deliberate, structured Handoff document for the current objective into the active notepad and force a git push so it syncs across machines. Use when wrapping a session, handing to a teammate or fresh agent, hitting a milestone, or asked to "create a handoff", "write a handoff", "checkpoint for next session", "hand this off". Writes to <notepad>/handoffs/<date>-<topic>.md (NOT a temp dir), redacts secrets, references artifacts by path/URL, suggests next skills. In agent-notepad this is the on-demand Handoff tier — distinct from the continuous Notes tier (NOTES.md + journal) that hooks keep fresh automatically.
---

# handoff — publish a deliberate Handoff doc into the notepad

## Notes vs Handoff — the terminology split (read first)

agent-notepad keeps working memory in **two tiers**, and this skill owns only the second:

- **Notes** — the *continuous* tier. `NOTES.md` (compact, rewritten in place) plus the
  append-only journal (`sessions/<ISO8601>_<id>.jsonl`). Kept fresh **automatically** by
  the Stop / PreCompact / UserPromptSubmit hooks and auto-loaded every SessionStart. You
  do **not** invoke a skill for Notes — they just accrue.
- **Handoff** — the *deliberate* tier. A single **structured document** you publish on
  demand at a meaningful boundary (milestone, teammate hand-off, end of a work block).
  This is what `/handoff` produces.

A Handoff **summarizes** the current Notes into a durable, shareable artifact; it does
**not** replace them. Notes are the stream; a Handoff is a snapshot you deliberately cut
and push. When in doubt: routine progress → let the Notes hooks capture it; a real
checkpoint someone else (or a fresh you) will read cold → publish a Handoff.

## What this does

1. Resolves the active **notepad** (nearest ancestor of cwd with `NOTES.md`).
2. Writes the structured handoff to **`<notepad>/handoffs/<date>-<topic>.md`** —
   inside the notepad, **never** the OS temp dir — so it is versioned and syncs.
3. **Redacts secrets** (API keys, tokens, bearer/JWT, private keys, `password=`…).
4. **References artifacts by path or URL** (PRDs, plans, ADRs, commits, diffs, per-repo
   `df-context-store` findings) instead of duplicating their content.
5. **Suggests next skills** the receiving agent should invoke.
6. **Forces a `git push`** of the notepad (git add → commit → push, best-effort) so the
   handoff is immediately available on other machines / to teammates.

## When to use

- Wrapping a session or work block; handing to a teammate or a fresh agent.
- Hitting a milestone worth a durable checkpoint.
- Explicit asks: "create a handoff", "hand this off", "checkpoint for next session",
  "prep for a fresh agent", "summarize the session for continuation".

For *automatic* survival across auto-compaction, that is the Notes hooks' job — you do
not run this skill for that.

## How to run

Compose the handoff **body** (the sections below), then publish via the helper. The
helper writes the file, redacts, commits, and pushes; it prints the path it wrote.

```bash
# body on stdin; args: <notepad-root> <topic>
printf '%s' "$HANDOFF_BODY" \
  | "${CLAUDE_PLUGIN_ROOT}/lib/publish-handoff.sh" "$NOTEPAD_ROOT" "Arb bot milestone"
```

`$NOTEPAD_ROOT` is the current notepad (the nearest ancestor with `NOTES.md`; the
SessionStart hook already resolved it). The helper **refuses** (non-zero exit, no write)
if the target is not a notepad — a Handoff only belongs in a notepad.

### Suggested body sections

- **Objective / current goal** — one line; the done-criteria from `SCOPE.md`.
- **State** — what is done, what is in flight.
- **Decisions** — key choices + rationale (mirror durable ones into the code repo's
  `DECISIONS.md` via context-management).
- **Next action** — the single most important next step.
- **Open threads / blockers.**
- **Artifacts** — reference by `repo:file:line`, PR/commit SHA, or URL. Do **not** paste
  their contents.
- **Suggested next skills** — e.g. `df-tdd-developer`, `df-qa`, `context-management`,
  plus whichever memory-recall skill the instance binds (Tier-2; do not assume a name).

## Guarantees & boundaries

- **Target-overridable / test-safe:** the notepad root is an argument; `AGENT_NOTEPAD_DATE`
  overrides the date stamp and `AGENT_NOTEPAD_PUSH_LOG` records push attempts. Tests point
  all three at temp dirs — the helper never hardcodes a real repo or remote.
- **Best-effort push:** every git step is `|| true`; a missing/broken remote still leaves a
  written, committed handoff and a zero exit.
- **Writes only under the notepad.** Never touches `~/.claude`, the palace, or any repo
  outside the notepad. Live memory is read-only elsewhere; this skill only writes files
  and pushes the notepad's own git repo.
