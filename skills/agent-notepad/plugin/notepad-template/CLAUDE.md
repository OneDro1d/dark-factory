# <group>-<objective> — agent-notepad working memory

> This directory is an **agent-notepad**: per-objective working memory (one standalone git
> repo per objective). It is NOT a code repo — the code lives in the repos listed in
> `repos.manifest.json` and is driven from here via absolute paths, never by `cd`-ing.

<!-- Replace the bracketed placeholders when this notepad is created (U7 /scope-init). -->

## Objective

<one-sentence objective — what "done" looks like. Full charter in SCOPE.md.>

## Repos in scope

Authoritative list is `repos.manifest.json`. Drive each via absolute path
(`git -C /abs/path/to/repo …`). Every repo should carry a `df-context-store`
(`.claude/context/`); a missing store surfaces a SessionStart warning.

- `<abs-path>` (branch `<branch>`, role `<role>`)

## Read-first (every session)

1. `NOTES.md` — compact working memory (auto-loaded on start).
2. `DIGEST.md` — the standing caveats, hand-maintained, **committed**, auto-loaded. It was
   once derived and gitignored; that producer was removed 2026-07-29.
3. `repos.manifest.json` — the code repos this notepad drives.
4. Each in-scope repo's `.claude/context/SERVICE-MAP.md` → `DATA-FLOW.md` → `FINDINGS.md`
   → `DECISIONS.md` — read the store instead of re-scanning the repo.

## Dispatch rules

- **Notes tier** (ephemeral task progress) → this notepad: rewrite `NOTES.md`, append the
  session journal (`sessions/<ISO8601>_<id>.jsonl`).
- **Durable, code-anchored, single-repo** learnings → that repo's `FINDINGS.md` /
  `DECISIONS.md` (via `knowledge-keeper` + `commit-sync`), not here.
- **Deliberate structured handoff** → `handoffs/<date>-<topic>.md` (`/handoff`); forces a push.
- Two commit streams: **code → code repos** (governed by the commit gate in
  `.claude/settings.json`) and **Notes → this notepad** (best-effort sync). Record every
  code commit SHA in the journal.

## Guardrails

- Never `cd` into a code repo — operate via absolute paths.
- Keep `NOTES.md` ≤150 lines, secrets/PII redacted; never compress away a caveat.
- Agent code-commits are staleness-gated against each repo's context store.
