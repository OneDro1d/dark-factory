---
title: QA (Deploy & Test) — Stage Guide
stage: 5. QA
type: stage-guide
status: living
consumes: Developer code+tests, Infra deployment spec, PO test scenarios + definition of done, observability
produces: Test Plan & Results (+ "Works?" verdict + verified deployed system)
---

# QA (Deploy & Test) — Stage Guide

## TL;DR

QA deploys the built system to test/acceptance, runs the PO's real-life scenarios against it, and returns a **"Works?" verdict**. It produces **one must-have doc: the Test Plan & Results** — every PO scenario mapped to a test case with pass/fail evidence. A Pass forwards the verified system to PO Final Sign-off and Operations; a Fail loops back to the lane that broke.

## Where this stage sits

`Developer ∥ Infrastructure Architect → **QA (Deploy & Test)** → "Works?" → PO Final Sign-off → Operations`

## Inputs (must arrive from upstream)

| Input | From | Why QA needs it |
|---|---|---|
| **PO test scenarios + definition of done** | PO (1) | Defines what "works" means — the pass bar |
| Deployed system + deploy procedure | Infra (4) | The thing under test, and how to stand it up |
| Built services + their tests | Developer (3) | Unit/integration tests to run before E2E |
| Observability (metrics/logs/traces) | SA (2)/Infra (4) | Evidence that a scenario actually ran end-to-end |
| Test Strategy hints (E2E/JMeter/holdout) | SA (2) optional | Starting point for automation |

## Must-have output (the small list)

| Output | Purpose | Template |
|---|---|---|
| **Test Plan & Results** | PO scenarios → test cases → pass/fail evidence · quality gates · "Works?" verdict | [`templates/test-plan-results-template.md`](templates/test-plan-results-template.md) |

## Optional outputs

- Held-back acceptance suite / regression suite (the cases withheld from the builder)
- Load / performance results

## Exit gate

> **Pre-test gate — the eyes work (run first):** Before testing any scenario, confirm the Observability Surface Infra delivered actually works: every required dashboard renders **live** data, the `$correlationId` query resolves across services, alert rules evaluate ([`reference/observability-standard.md`](../../reference/observability-standard.md) bar). **If the eyes don't work, stop — the verdict is blocked, not Fail-by-scenario.** Route back to Infra (4): without the surface, per-scenario evidence cannot be captured and every "pass" would be an unverifiable assertion. This is the precondition that "these are the agents' eyes" makes explicit — broken eyes make testing limited-to-impossible.
>
> **Coverage test:** Does every PO real-life scenario have a test case with captured pass/fail evidence (metric, log line, or trace via correlationId)? Is the "Works?" verdict justified by that evidence, not by assertion?

If a scenario has no evidence, the verdict is not earned. Fail loops back; Pass forwards the deployed system to Operations.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Through the data-transform lens

See [`reference/data-transform-model.md`](../../reference/data-transform-model.md). QA **executes the validation rules**:

- Each PO acceptance criterion is a validation rule → a test. **LOCAL** rules → tests that feed bad input at an edge and assert it is **rejected**; **GLOBAL** rules → **reconciliation tests** across systems/time, asserting both the invariant and the `authority` tie-break.
- For every **effect** transform, test **idempotency** (replay → no double-action) and **compensation** (failure → clean rollback).
- A test that asserts nothing about a validation rule protects nothing — coverage is measured against the rules, not the screens. The "State 0 → Trigger → State 1" check is a transform-equality assertion.

## Interaction mode

**AI, supervised by humans.** QA agents author and run tests autonomously; the human gate is on the *verdict* — promoting a system toward production is a human-approved decision in regulated (HIPAA) contexts.

## Workflow

1. **Check the eyes first.** Open the Observability Surface Infra handed off: confirm every required dashboard renders live data and a `$correlationId` query resolves across services. If the eyes are dark, halt and route to Infra (4) before testing — you cannot capture evidence through a blind instrument.
2. **Map, don't invent.** Every test case starts from a PO real-life scenario. One scenario → at least one test case.
3. **Run the pyramid in order:** unit (from Developer) → integration → E2E (JMeter against the deployed cluster) → the held-back acceptance suite. Stop and report at the first quality-gate breach.
4. **Capture evidence by correlationId.** A scenario "passed" only if its run is traceable in observability — Directive 1 makes this possible; QA exploits it.
5. **Record results in the template**, including failures (publish bad alongside good).
6. **Verdict:** Pass / Conditional / Fail. Conditional requires explicit, owned, time-boxed open items.

## Handoff

- **Pass** → the deployed+verified system, the JMeter plans, and the observability evidence move to **Operations**; the verdict moves to **PO Final Sign-off**.
- **Fail** → route to the owning lane: a code defect → Developer; a deploy/topology defect → Infrastructure Architect; a wrong/ambiguous requirement → PO.

## Failure modes

- Tests assert screens, not real work (the PO scenario weakness propagating downstream).
- "Pass" with no observability evidence — unverifiable claim.
- Skipping the holdout set (the dark-factory regression guard).
- Verdict auto-promoted without the human gate in a regulated context.

## References

- [`reference/data-transform-model.md`](../../reference/data-transform-model.md) — the lens: tests execute validation rules (LOCAL → reject, GLOBAL → reconcile); test effect idempotency + compensation
- [`reference/8-implementation-patterns.md`](../../reference/8-implementation-patterns.md) — at-least-once + DLQ behaviour under test
- [`reference/observability-standard.md`](../../reference/observability-standard.md) — the eyes QA verifies before testing: the dashboards/queries that are the evidence source
- [`reference/10-prime-directives.md`](../../reference/10-prime-directives.md) — Directive 1/6: observability is the evidence source
- [`01-adversary-qa.md`](01-adversary-qa.md)
