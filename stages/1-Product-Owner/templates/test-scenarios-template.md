---
title: Test Scenarios — <Product Name>
stage: 1. Product Owner
type: test-scenarios
status: template
---

# Test Scenarios — <Product Name>

## TL;DR

<One paragraph: the real-life situations that, if they pass, prove the product solves the right problem.>

## Write each scenario as a state change

The most efficient, most verifiable way to specify a test is as a **state transition** — every product behaviour *is* a state change, so frame it that way:

- **State 0** — the world/system state *before* (preconditions, data already present).
- **Trigger** — the single input data or action that fires.
- **State 1** — the exact end state *after* (what changed, what now holds).

This is **deterministic**: given State 0 and the Trigger, State 1 is fixed — so validation is a mechanical equality check (does the observed end state equal the specified State 1?), not a judgement call. QA captures State 0, applies the Trigger, and asserts State 1 from observability (metric / log / trace by correlationId). Use this shape wherever the scenario allows; reserve free prose for the human framing around it.

## Scenarios

Each scenario is a realistic user situation expressed as a state change, not a feature assertion. Concrete enough for SA, Developer, QA, and Ops to design and test against.

### TS-01 — <name>

- **State 0 (precondition):** <the world/system state before — data, positions, config already present>
- **Trigger:** <the single input data or action that fires>
- **State 1 (end state):** <the exact, observable end state — what changed, what now holds>
- **Situation:** <who, where, under what real conditions — the human framing around the transition>
- **Failure modes covered:** <connectivity loss, bad data, concurrency…>
- **Proves requirement(s):** R-0x

### TS-02 — <name>

<…>

## Definition of Done

The product is done when these scenarios pass:

- [ ] TS-01 <one line>
- [ ] TS-02 <one line>

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Scenario coverage check

- Every **must** requirement has at least one scenario.
- Scenarios include happy path **and** edge **and** failure modes (not just the happy path).
- Each scenario states an observable outcome QA can capture via metrics/logs/traces.

## Downstream use

- SA turns each scenario into a Data Flow path.
- QA turns each scenario into a test case with pass/fail evidence.
- Ops derives SLOs from the scenarios' promised outcomes.
