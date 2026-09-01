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

## ⚠️ The handoff is the SINGLE ENTRY POINT for a cold session

Operator decision, 2026-09-01. **A handoff must be the only document a fresh session has to
read to become oriented.** Not the first of five — the only one. Everything else it needs, it
reaches *through* the handoff.

That is a contract on what a handoff must contain:

- **Where the work stands**, in a few sentences a cold reader can act on.
- **The one next action.** Not a menu.
- **A link to every artefact touched** — the mission map, the tickets, the PRs, the files, the
  findings. By path or URL, in a list, so nothing has to be hunted for.
- **What is blocked and on whom.**

⚠️ **It POINTS. It does not RESTATE.** The Mission Map holds the decisions; the tracker holds
ticket state; the repos hold the code. A handoff that copies those becomes a second store of
the same facts, and two stores drift — which is the one-artifact-two-homes failure this whole
model exists to remove. **Entry point, not authority.** If you find yourself explaining a
decision rather than linking to where it was recorded, stop and link.

⚠️ **Test it the only way that works: could someone who was NOT in this session pick up this
file alone and continue?** If they would have to already know which mission, which ticket, or
which repo — it is not a handoff yet, however complete it feels from inside the session.

### Why this matters more after compaction than at a milestone

Native compaction is lossy and unversioned. When it fires, the hooks re-inject what they have —
so whatever the handoff does *not* carry is simply gone from the new window. A five-document
read order degrades to whichever documents the compacted agent still remembers to open. One
self-sufficient document does not have that failure mode.

For *automatic* survival across auto-compaction, the Notes and PreCompact hooks do the
mechanical capture — you do not run this skill for that. **But they capture session mechanics:
files touched, recent intent.** They cannot know which ticket was claimed or what "done" means
here. That judgement is this skill's, which is why the 85% context gate tells you to call it
rather than trusting the hooks alone.

## How to run

Compose the handoff **body** (the sections below), then publish via the helper. The
helper writes the file, redacts, commits, and pushes; it prints the path it wrote.

```bash
# Resolve the helper under BOTH install modes.
#   plugin mode     -> ${CLAUDE_PLUGIN_ROOT}/lib/...
#   install.sh mode -> ~/.claude/hooks/agent-notepad/lib/...
# ⚠️ ${CLAUDE_PLUGIN_ROOT} is set ONLY when agent-notepad is loaded as a PLUGIN. Under
# install.sh it is EMPTY, and the bare "${CLAUDE_PLUGIN_ROOT}/lib/publish-handoff.sh" this
# file used to print collapsed to "/lib/publish-handoff.sh" — an absolute path that does not
# exist. Measured 2026-08-31: the installed copy on this estate's laptop is THIS file, and
# CLAUDE_PLUGIN_ROOT was unset, so the command this skill documented could not run. The
# corrected line already existed in the plugin-bundled twin, which nothing installs.
PUBLISH_HANDOFF="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/hooks/agent-notepad}/lib/publish-handoff.sh"

# body on stdin; args: <notepad-root> <topic>
printf '%s' "$HANDOFF_BODY" \
  | "$PUBLISH_HANDOFF" "$NOTEPAD_ROOT" "Arb bot milestone"
```

If `$PUBLISH_HANDOFF` does not exist, agent-notepad is not installed — say so and stop.
Do **not** hand-roll the write: the helper owns the notepad-root guard, the redaction
pass, the commit and the forced push, and the `AGENT_NOTEPAD_*` test overrides.

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
