---
title: Requirements — <Product Name>
stage: 1. Product Owner
type: requirements
status: template
---

# Requirements — <Product Name>

## TL;DR

<One paragraph: the MVP in a sentence, and the must-have capability that defines it.>

## MVP scope

**In:** <the target slice for v1>
**Out (this version):** <deferred — links to non-goals in Vision>

## Capabilities

| ID | Capability | User | Priority | Acceptance criteria (testable) | Source |
|---|---|---|---|---|---|
| R-01 | <capability> | <persona> | must | <observable, testable condition> | <input source> |
| R-02 | <capability> | <persona> | should | <…> | <…> |

Priority = must / should / could. Every **must** has testable acceptance criteria and a Test Scenario.

## Data & validation (the data-transform lens)

Per capability, name the **data** and the **rules** over it — this is what the SA turns directly into the Data Model + Data Flow. See [`reference/data-transform-model.md`](../../../reference/data-transform-model.md).

| Capability | Data (schema) | `origin` (web / mobile / scan / API / service) | `authority` (system-of-record) | `governance` (class · retention) | Validation rules (predicate + business scope: one record / across systems) | Effect? (touches outside world) |
|---|---|---|---|---|---|---|
| R-01 | `<fields>` | `<where it enters>` | `<who is SoR for this fact>` | `<PHI/PII · period>` | `<predicate → one-record \| cross-system>` | `<yes/no>` |

`origin` is for audit only — never a trust signal. State each rule as a **predicate + business scope** (one record, or must agree across systems); the SA assigns the formal locus (`LOCAL`/`GLOBAL`) and mechanism. Any capability whose acceptance criterion touches the outside world (send / charge / notify / external write) is an **effect**: flag it so the SA assigns idempotency + compensation.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Traceability (optional but recommended)

| Requirement | Source (call / doc / ticket / regulation) | Confidence |
|---|---|---|
| R-01 | <source> | Confirmed / Inferred / Assumption |

## Notes for the SA

Requirements state **what**, not **how**. Architectural constraints (must use AMQP, must run on EKS) belong here only if they are genuine product/compliance constraints, not design preferences — and are labelled as such.
