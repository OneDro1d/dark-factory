---
name: agent-notepad
description: Persistent, per-objective working memory for coding agents — one standalone git "notepad" repo per objective that survives context compaction, spans multiple code repos from a single session, keeps an append-only journal, and mirrors into an episodic memory index. Ships as a Claude Code plugin (hooks + skills + notepad template + a memory adapter). Evolves and supersedes handoff-auto. Use when setting up objective-scoped agent memory, running several long-lived concurrent agent sessions, surviving auto-compaction, enabling `/clear` instead of `/compact`, driving several code repos from one place without `cd`, or installing/uninstalling the notepad hooks. Triggers on "agent notepad", "working memory notepad", "per-objective memory", "scope-init", "survive compaction", "cross-repo agent memory", "supersede handoff-auto".
---

# agent-notepad — persistent, per-objective working memory

## What this is

A **notepad** is one standalone git repo per objective (`<group>-<objective>`, e.g.
`proj-arbbot`), holding the agent's *working memory* for that objective. It survives
context compaction, keeps history (append-only journal, not a rewrite), spans several
code repos from a single session, and syncs across machines. It is the short-term,
auto-loaded tier that complements a curated long-term store — and it **evolves and
supersedes** [`handoff-auto`](../handoff-auto/SKILL.md): the same continuity machinery,
now objective-scoped instead of cwd-scoped, with history and cross-repo reach.

Product = **a Claude Code plugin**: hooks + skills + a notepad template + a small Python
memory adapter. No binary, no daemon. Full rationale in [`DESIGN.md`](./DESIGN.md).

## Why it beats naive auto-handoff

`handoff-auto` keys by cwd → one rewritten file → parallel sessions clobber, no history,
single-repo. A notepad gives **zero contention** (separate folder + cwd + git repo per
objective), **append-only history**, and **cross-repo context** driven from one place via
absolute paths (never `cd`). The episodic memory index is exercised at both ends by hooks
(write-mirror on Stop, query on digest build), so "memory is actually used" is enforced,
not left to agent discretion.

## The four layers

| Layer | Anchored to | Where |
|---|---|---|
| **Working memory (Notes)** | the *task* | the notepad repo (`NOTES.md` + journal) — this skill |
| **Per-repo context store** | *code* (`file:line`) | `<code-repo>/.claude/context/` — df-context-store |
| **Episodic index** | journals, by prefix | the memory index (MemPalace ref impl) — mirror + digest |
| **Curated** | distilled cross-project | the long-term store ([Engram](../../starter-kit/instance/AUTHENTICATION.md#engram) ref) — existing |

## Notepad layout

```
proj-arbbot/
  CLAUDE.md            # orientation: objective, repos-in-scope, read-first/dispatch rules
  NOTES.md             # compact working memory, auto-loaded (≤150 lines, redacted)
  SCOPE.md             # charter: objective, done-criteria, repo subset
  DIGEST.md            # standing caveats, hand-maintained, COMMITTED, auto-loaded
  repos.manifest.json  # the CODE repos this notepad drives
  sessions/
    index.json         # session metadata index
    <ISO8601>_<id>.jsonl   # append-only journal, one file per session
  handoffs/            # deliberate structured handoff docs (/handoff → forces push)
  .claude/settings.json  # notepad-scoped hooks incl. the commit gate
```

## The hooks (what runs when)

- **SessionStart** — best-effort `git pull`, then FILE-READS-ONLY inject `NOTES.md` +
  `DIGEST.md` + `repos.manifest.json` (~1–3 s). Outside a notepad, degrades to
  `handoff-auto` behavior.
- **Stop** — append deterministic journal entries (files touched, commands, a stop
  marker), upsert `sessions/index.json`, **mirror the journal into the memory index**,
  best-effort `git push`.
- **UserPromptSubmit** — soft nudge to keep `NOTES.md` current (backed by the PreCompact floor).
- **PreCompact** — deterministic floor: snapshot recent intent into `NOTES.md` + journal
  before compaction, so `/clear` rehydrates losslessly.
- **PreToolUse(Bash)** — the **commit gate** (ships in the *notepad's* `.claude/settings.json`,
  arms only in notepad sessions): blocks *agent* `git -C <code-repo> commit`s that drift
  from that repo's df-context-store.

## Install

```bash
# from the plugin dir; installs to the STABLE path ~/.claude/hooks/agent-notepad/,
# merges the four user-level Notes hooks into ~/.claude/settings.json (idempotent),
# installs this skill, and UNWIRES handoff-auto (files kept — reversible).
plugin/install.sh                 # targets $HOME
plugin/install.sh --target DIR    # targets DIR (used by the test harness against a temp HOME)
```

The installer backs up `settings.json` before editing it. To reverse: restore the backup
and re-wire handoff-auto. As a Claude Code plugin, the four Notes hooks are declared in
`plugin/.claude-plugin/plugin.json` via `${CLAUDE_PLUGIN_ROOT}`.

## A day in the life

1. `/scope-init proj-arbbot` — creates the notepad repo, interviews for objective +
   in-scope code repos, warm-starts `NOTES.md`, derives the memory wing (`proj`).
2. SessionStart auto-loads `NOTES.md` + `DIGEST.md`; you resume from state instead of
   re-deriving it. You work across the manifest's repos via absolute paths.
3. As you go, `NOTES.md` stays fresh (nudged each turn); durable code-anchored learnings
   go to each repo's `FINDINGS.md`/`DECISIONS.md` (df-context-store), not here.
4. You `git -C /abs/code-repo commit` — the commit gate checks it against that repo's
   store; a drifting commit is blocked with a fix hint, a compliant one passes.
5. On Stop, the journal appends + mirrors into the memory index; a background digest build
   queries the `proj` wing so a *sibling* objective's recent activity shows up in `DIGEST.md`.
6. Context fills → PreCompact writes the floor. You `/clear` instead of `/compact`; the
   next session rehydrates goal + next-action from `NOTES.md` alone.
7. At a real milestone, `/handoff` writes `handoffs/<date>-<topic>.md` and forces a push.

## Routing (where does this note go?)

Ephemeral task progress → `NOTES.md`. Durable + code-anchored + single-repo → that repo's
`FINDINGS`/`DECISIONS`. Cross-scope episodic (same prefix) → the memory index (mirror +
digest). Deliberate handoff → `handoffs/` + remote. Distilled/canonical → the curated store.

## Relationship to handoff-auto

Evolution, not coexistence: the `handoff-auto` machinery becomes the **Notes** tier; its
hooks are extended and the commit gate is added. The installer unwires `handoff-auto`
(leaving its files in place, reversible). Outside a notepad, behavior degrades to today's.

## Non-goals (v1)

No new DB/service (files are truth) · no live context-% trigger · no automatic `/clear`
(habit) · no shared mutable files · no cross-*group* auto-sharing · manual human
code-commits are not governed (agent commits only).
