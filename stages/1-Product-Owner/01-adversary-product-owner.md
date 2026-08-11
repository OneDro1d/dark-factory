---
title: Adversary Product Owner Review
stage: 1. Product Owner
type: adversary-process
status: living
---

# Adversary Product Owner Review

## TL;DR

An adversary attacks the three PO docs before handoff: find a way the factory could build the wrong thing and still satisfy the package, a requirement that is not testable, a scenario that only tests screens, or a missing non-goal. Verdict: **Pass / Conditional / Fail**.

## Review checklist (signal)

| Check | Pass? |
|---|---|
| Problem + business value are clear (Vision) | |
| Non-goals ("what this is not") are explicit | |
| Every must-have requirement has testable acceptance criteria | |
| Test scenarios describe real work, not screen assertions | |
| Scenarios cover happy path + edge + failure modes | |
| Cold SA test passes (an SA could design from these alone) | |
| Wrong-target test passes (no way to build the wrong thing and still comply) | |
| Claims labelled Confirmed / Inferred / Assumption / Open | |
| Each requirement carries its data + context (`origin`/`authority`/`governance`); each acceptance criterion is a validation rule tagged `LOCAL` or `GLOBAL`; outside-world triggers flagged as effects ([lens](00-product-owner-guide.md#through-the-data-transform-lens)) | |

## Verdict

- **Pass** — every check yes; cold SA + wrong-target tests pass.
- **Conditional** — minor gaps, owned and time-boxed.
- **Fail** — untestable requirement, screen-only scenario, missing non-goals, or a viable wrong-target path.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Adversary prompt

```text
You are an adversarial Product Owner reviewing a Vision, Requirements, and Test Scenarios package you did not write.
Using critical thinking:
- Find a realistic way the downstream factory could build something that satisfies this package but does NOT solve the real problem (wrong-target test).
- List requirements with no testable acceptance criteria.
- Find test scenarios that only assert screens/features instead of real user work.
- Find missing non-goals that invite scope creep.
- Run the cold SA test: where would an architect have to guess about product, domain, or prior versions?
Return: findings table (severity | check | evidence | fix) + verdict Pass/Conditional/Fail.
```

## What to attack

- **Target correctness:** the wrong-target path is the most expensive miss.
- **Testability:** a requirement you cannot test cannot gate QA.
- **Realism:** screen-only scenarios propagate into weak QA tests.
- **Scope:** missing non-goals.

## Parallel autonomous draft (optional)

For high-stakes packages, give the same raw inputs to a second AI to produce an independent draft; an adversary compares both blind and merges the stronger sections. Use when the cost of a wrong target is high.

## Output format

Findings table + verdict. A viable wrong-target path or an untestable must-have requirement forces **Fail**.
