---
name: df-product-owner
description: Dark Factory Product Owner stage: define Vision, Requirements as data contracts plus validation rules, and Test Scenarios — the semantics every later stage derives from. Triggers on "product owner", "requirements", "acceptance criteria", "test scenarios", "data contract", "what should we build".
---

# Dark Factory — Product Owner (define the semantics)

## Overview
The PO turns messy intent into a self-contained, testable target. It produces three must-have outputs: **Vision, Requirements, Test Scenarios.** Through the data-transform lens (`df-data-transform-lens`): **Requirements = data contracts + validation rules; Test Scenarios = those rules as cases.** The PO owns the *semantics* (domain truth); the Solution Architect formalizes them.

## When to use
Defining what to build, writing requirements/acceptance criteria, or assembling the package a cold Solution Architect will design from.

## What the PO defines (with SMEs) — the semantics
Per capability, name the **data** and the **rules** over it:

| Field | What to capture |
|---|---|
| **Data (schema)** | the fields collected, conceptually |
| `origin` | real-world source: web form · mobile · scanned doc · 3rd-party API · another service (for audit — never a trust signal) |
| `authority` | who is system-of-record for this fact (a domain fact, e.g. "the bank owns balance") |
| `governance` | PHI/PII class, retention, residency |
| **Validation rules** | the business predicate + its **scope** (holds within one record, or must agree across systems/time) |
| **Effect?** | does the acceptance criterion touch the outside world (send/charge/notify/write-external)? Flag it so SA assigns idempotency + compensation |

You state **what must be true and who is authoritative**; the SA decides **where it's checked and how** (the formal `LOCAL`/`GLOBAL` locus + mechanism is SA's call).

## Instructions
1. **Vision** — why / what / who / value, and the **non-goals** ("what this is not").
2. **Requirements** — capabilities + testable acceptance criteria, each as a data contract + validation rule (use the table above).
3. **Test Scenarios** — concrete real-life situations, not screen assertions. Frame each as a **state change**: `State 0 (precondition) → Trigger (input) → State 1 (end state)`, with happy path + edge + failure modes. These are the executable evidence standard downstream.
4. **Label every claim** Confirmed / Inferred / Assumption / Open — never silently invent product facts.
5. Mark any outside-world trigger as an **effect**.

## Exit gate (the cold-SA test)
Could a Solution Architect who knows nothing about the product design the right architecture from Vision + Requirements + Test Scenarios **alone**? Is there any way to build the wrong thing and still satisfy the package? If yes, clarify before handoff.

## Don't
- Don't formalize schemas / Avro contracts / enforcement locus — that's the SA's job (`df-solution-architect`). State the semantics; let the SA realize them.
- Don't write scenarios that test screens instead of real work.
- Don't omit non-goals (the biggest scope-creep guard).
