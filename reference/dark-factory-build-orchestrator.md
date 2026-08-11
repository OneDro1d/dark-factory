---
name: dark-factory-build
description: End-to-end Dark Factory build orchestrator — take a feature or project from intent to verified, documented, shipped software. Chains the df-* stages through the data-transform lens, dispatches parallel sub-agents under Promise Theory with adversarial verification, writes the DF spec docs, builds test-first (TDD), executes autonomously in dev/non-prod with hard stops at real-world boundaries, and documents every stage as tickets (Jira / Monday / user-selected) with story points calibrated at 2 SP = 1 human-day. Use when asked to "build this the dark factory way", "run a dark factory build", "finish this project autonomously with DF docs + TDD + tickets", or to take a spec to done end-to-end.
---

# Dark Factory Build — end-to-end orchestrator

## Overview

This skill runs a complete Dark Factory build: **intent → semantics → design → tests → code → verification → live proof → shipped + documented.** It is the conductor; the per-stage `df-*` skills do the work. Everything is modeled through the **data-transform lens** (data nodes + pure/effect transforms + validation rules + authority), built **test-first**, **verified adversarially** (never on a self-report), executed **autonomously in dev/non-prod**, and **documented as tickets + DF spec docs + memory** at every step.

It is the generalization of a real run: a DEX arbitrage bot taken from half-finished to a liquidity-aware arbitrage engine with 5 DF docs, TDD + ~290k-case adversarial fuzz, and a live on-chain no-overshoot proof — all ticketed and committed.

## When to use

- "Build this the dark factory way" / "run a DF build" / "do this end-to-end autonomously."
- A spec or half-built project needs to be finished with docs + TDD + verification + tickets.
- Any non-trivial feature where you want the full discipline: semantics first, blind-verified, evidence-backed.

For a single stage only (just the PO doc, just TDD), invoke that `df-*` skill directly instead.

## The pipeline

Run the stages in order. Each stage has an owning `df-*` skill, a concrete artifact, and a ticket. Earlier stages gate later ones (a cold reader must be able to build the next stage from the previous artifact alone).

| # | Stage | Skill | Artifact | Ticket |
|---|---|---|---|---|
| 0 | **Frame** | `df-data-transform-lens` | the shared model (data nodes, transforms pure\|effect, validation rules, authority) | the epic |
| 1 | **Product Owner** | `df-product-owner` | `docs/dark-factory/01-product-owner.md` — Vision, Requirements as data contracts + validation rules, Test Scenarios, non-goals | 1 story |
| 2 | **Solution Architect** | `df-solution-architect` | `02-solution-architect.md` — Data Model, Data Flow (transform graph, idempotency + compensation per effect), Service Map, enforcement loci (LOCAL/GLOBAL) | 1 story |
| 3 | **Infrastructure** | `df-infrastructure` | `03-infrastructure.md` — DTAP, where data lives, trust boundaries → mechanisms, secrets, deploy/live-test runbook | 1 story |
| 4 | **Observability** | `df-observability` | `04-observability.md` — the consumable surface (dashboards + queryable traces keyed to scenarios), "verified rendering live data" | 1 story |
| 5 | **Developer (TDD)** | `df-tdd-developer` | the code — RED→GREEN→REFACTOR, test list = PO validation rules + scenarios | 1 story per unit |
| 6 | **Adversary gate** | `df-adversary-gate` | a blind verifier's evidence (fuzz/holdout test + exit code), re-run by you | folds into the unit/QA story |
| 7 | **QA** | `df-qa` | `05-qa-*.md` — verdict + unforgeable evidence per scenario (by correlationId / tx hash), holdout result | 1 story |

The PO requirements (validation rules + test scenarios) are the **single source of truth** that flows through every later stage: SA assigns each rule an enforcement locus, the developer's test list IS those rules, QA's evidence standard IS those scenarios. Do not invent a test list or acceptance criteria downstream — derive them.

## Composition with other skills (ordering matters)

1. `loom-recall` — search memory before each non-trivial decision (runs first).
2. `critical-thinking` — verify assumptions before an irreversible action (especially before spending funds / touching shared state).
3. `df-data-transform-lens` — the frame everything else is expressed in.
4. the `df-*` stage skills — per the pipeline table.
5. `df-dispatch-subagents` + `df-adversary-gate` — for parallel work and verification (below).
6. `work-autonomously` — gates the action: act in dev/non-prod, HARD-STOP at real-world boundaries (below).
7. `creating-skills` — only if the build produces a new skill.

## Promise-Theory sub-agent dispatch (parallelism + verification)

Use `df-dispatch-subagents` **every time** you spawn an agent. The seam is a trust boundary.

- **Parallelize the parallelizable.** Independent DF docs (SA, Infra, Observability) and independent finder/reviewer passes fan out as background agents. Keep the **correctness-critical core in-house** (e.g. the financial sizing math was built by the orchestrator, not delegated).
- **State the promise + the exact unforgeable evidence** the agent must return: file path + `wc -l` + real `file:line` citations, or a test file + the literal `go test` PASS/FAIL summary + case count. Never accept "done / all passing."
- **Blind synthesis (anti-Goodhart):** give a build/verify agent the spec, **withhold the acceptance/holdout cases**. The adversary verifier must derive its own attack and must NOT read your tests.
- **On return, verify the evidence yourself** (`df-adversary-gate`): re-run the test, read the file, re-check the citation. A missing piece of the promised evidence ⇒ treat as UNVERIFIED and re-dispatch or check independently. One agent never vouches for another.

## Autonomy + hard stops

Per `work-autonomously`: **default is action in dev/test/local/non-prod; resolve ambiguity via the toolchain (memory → codebase → internet → docs) before asking.**

HARD-STOP and ask for explicit go-ahead before any irreversible real-world action: prod-DB writes, prod deploys, merging PRs / pushing to a protected branch, outbound email / public posts, customer-visible config, **and any financial transaction or on-chain spend.** A live/burner test with real funds requires explicit, scoped authorization (e.g. "spend from this burner, small amounts") — and even then, run `critical-thinking` preflight checks before the first irreversible call (verify balances, decimals, that you're not clobbering existing state).

Pushing to a **feature branch / your own project repo** is fine; merging and prod are not. Dev DB read/write is fine; prod DB is a hard stop.

## Documentation — everything, at every stage

The build is not done until it is documented in three places:

1. **DF spec docs** in `docs/dark-factory/` (01–05) — committed with the code.
2. **Tickets** (see below) — status moved + evidence (commit SHAs, tx hashes, test counts) recorded per stage.
3. **Memory** — canonical engram (project record + reusable lessons in `patterns`/`platform-libs`) and the local memory index. Save a record at each meaningful checkpoint, not just at the end.

Commit cadence: **one commit per TDD unit / per stage, pushed frequently** to a feature branch or the project repo. Each commit message states what was verified (build/vet/test/-race green, static build, etc.).

## Ticketing + story points

Pick the tracker the user names (Jira, Monday, or other). If unspecified, ask once which tracker + project/board.

**Structure:** one **epic** for the build; one **story per DF stage** (and per TDD unit when units are independent). Move each ticket through the workflow as you go (e.g. Ready → Doing → Review/Need-Input → Done), and on completion fill the evidence fields (Refs = commit SHAs / file paths / engram IDs; Verification = the exact command + result that proves done).

**Story points — calibrate at `2 SP = 1 day of work for a human` (this skill's standing rule).** This is a *human-effort* estimate (what the work would take a skilled human), not how fast the agent does it. Only applies to trackers that record points (Jira and similar); Monday status-only boards skip points.

| SP | Human effort | Examples |
|---|---|---|
| 1 | ~½ day | small doc, one validation rule + tests, a config/wiring change |
| 2 | ~1 day | a DF stage doc, a self-contained TDD unit (engine/client), a service skeleton |
| 3 | ~1.5 days | cross-cutting change, multi-file refactor, a new integration leg |
| 5 | ~2.5 days | a new subsystem, the correctness-critical core + its adversarial gate |
| 8 | ~4 days | architectural change / new pattern with extensive testing |
| 13 | ~6.5 days | too big — **break into smaller stories** |

Rules: every points-tracked ticket gets an estimate; anything above 8 is decomposed; if you can't estimate, ask. (Note: this human-day calibration is deliberately distinct from the older "2 SP ≈ 2h AI-assisted" Jira baseline some existing boards use — when working a board that already has a calibration, follow the board's convention and say so; otherwise use 2 SP = 1 human-day.)

## End-to-end checklist (make these TodoWrite items)

- [ ] Recall + frame the work through the data-transform lens; confirm tracker + project/board.
- [ ] Create the epic + per-stage stories (points at 2 SP = 1 human-day where tracked).
- [ ] Stage 1 PO doc (`df-product-owner`) → ticket Done + committed.
- [ ] Stages 2–4 (SA / Infra / Observability) — dispatch as parallel Promise-Theory agents; verify each artifact (file + citations) before trusting; tickets Done.
- [ ] Stage 5 TDD (`df-tdd-developer`) — RED→GREEN→REFACTOR per unit; keep the critical core in-house; commit + push per unit; tickets Done.
- [ ] Stage 6 adversary gate (`df-adversary-gate`) — blind verifier, withheld holdout; re-run its evidence yourself; commit the regression test.
- [ ] Stage 7 QA (`df-qa`) — execute scenarios, capture unforgeable evidence (correlationId / tx hash), write `05-qa-*.md`, verdict.
- [ ] Full gate: build + vet + tests (+ `-race` / static where applicable) green; deploy/live artifacts render.
- [ ] HARD-STOP check before any prod/financial/outbound action — ask if crossed.
- [ ] Save to memory (engram project record + reusable `patterns`/`platform-libs` lessons + local index); close the epic.

## Worked example — a DEX/NAV arbitrage bot (2026-06)

Intent: finish a Uniswap-v3 ⇄ external-NAV arbitrage bot. Run:
1. Framed via the lens: NAV = external source-of-truth constant; pool price = the controllable variable; the centerpiece rule (VR-3.2) = "move pool to NAV without overshooting."
2. PO doc with that rule + 10 test scenarios; SA/Infra/Observability docs **fanned out to background agents** under Promise Theory and **verified against the real code** (line counts + `file:line` citations checked, not the agents' self-reports).
3. TDD'd the sizing math **in-house** (closed-form, sqrtPrice space, no-overshoot structural) — RED→GREEN→REFACTOR; committed + pushed per unit.
4. **Adversary gate:** a blind verifier wrote a ~290k-case fuzz it derived itself (never saw my tests); I re-ran its evidence → HOLDS; committed as a regression guard.
5. **QA:** live on-chain proof from an authorized burner (small funds, `critical-thinking` preflight on balances/decimals/no-clobber) — created the pool, the bot sized 0.366931 of the trading token and moved the price 1.050000 → 1.000145 (toward NAV, no cross); verdict doc `05-qa-live-test-result.md` with tx hashes.
6. Every stage ticketed on the project board and moved to Done with evidence; saved to engram + local memory. Prod/close-loop steps that needed live secrets were **hard-stopped** for explicit go-ahead.

## Anti-patterns

- Inventing acceptance criteria or a test list downstream instead of deriving them from the PO rules/scenarios.
- Trusting a sub-agent's "done / all passing" without re-running its evidence.
- Letting the adversary verifier read your tests (kills blind synthesis).
- Delegating the correctness-critical core (money math, security logic) to a sub-agent instead of building + owning it.
- Skipping tickets or doc updates "to move faster" — the documentation IS a deliverable.
- Proceeding past a hard-stop boundary because authorization was given once for a different action.
- Estimating points by agent speed instead of human effort (the calibration is human-day-based).
