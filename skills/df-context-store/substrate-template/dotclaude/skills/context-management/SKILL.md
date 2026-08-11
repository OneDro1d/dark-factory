---
name: context-management
description: Maintain and compress the context store so analysis is done once and reused, never repeated. Use to record a confirmed root cause, an architecture decision, or a service/contract change; or to compress sprawling notes back into the terse store. Triggers on "remember this", "update the context", "record decision", "we already analyzed this", "compress".
allowed-tools: Read, Write, Edit, Grep, Glob
---

# Context Management (analyze once, reuse forever)

Goal: keep `.claude/context/` the single, terse, trustworthy memory so agents never re-scan the repo to re-learn what's known. This is the main token-saving lever.

## The store
- `SERVICE-MAP.md` — components + flows (one line each).
- `FINDINGS.md` — confirmed bugs/root causes (append-only ledger, status-tagged).
- `DECISIONS.md` — architecture decisions/rulings (ADR log).
- `<service>/CLAUDE.md` — deep per-service detail.
- shared-models `CLAUDE.md` — contract index.

## When to write
- **Confirmed root cause** → new `F-###` in FINDINGS.md (symptom, cause, `file:line`, status). So it's never re-investigated.
- **Design/architecture decision** → new `D-###` in DECISIONS.md (decision, why, source).
- **New/changed service, routing key, table, object-store key** → update SERVICE-MAP.md + the service CLAUDE.md + (if a contract) the shared-models index.
- **Status change** (OPEN→FIXED) → update the existing entry, don't duplicate.

## How to write (compression rules)
- One fact per entry. Cite a source (`file:line`, ruling, ticket) for every claim — no guessing.
- Prefer tables/IDs over prose. Replace, don't append, when a fact changes.
- If notes have grown long, distill to the durable fact and delete the scratch.
- Keep each context file roughly a screen — if it's growing, compress.

## Read-first reminder for every agent
SERVICE-MAP → FINDINGS → DECISIONS → the one relevant CLAUDE.md → source. Stop as soon as you have enough.

## Don't
- Don't record session chatter or anything the code/git already states.
- Don't let the store drift from code — if you find a stale entry, fix it (cite the code).
