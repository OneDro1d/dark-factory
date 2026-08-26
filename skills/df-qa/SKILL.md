---
name: df-qa
description: 'Run the Dark Factory QA stage — execute the validation rules as tests, capture unforgeable evidence per scenario (by correlationId), run the holdout, and return a Works? verdict. QA is the OBSERVER: a self-report is not an assessment. Use when testing a deployed system, mapping PO scenarios to test cases, verifying with observability evidence, or judging a release. Triggers on "QA", "test plan", "verdict", "evidence", "holdout", "E2E test", "does it work", "verify the release".'
---

# Dark Factory — QA (validation rules executed)

## Overview
QA deploys the built system, runs the PO's real-life scenarios against it, and returns a **Works?** verdict backed by **unforgeable evidence**. Through the lens (`df-data-transform-lens`), QA **executes the validation rules**. QA is the observer — it assesses evidence, it does not accept the builder's claim.

## When to use
Testing a deployed system, mapping PO Test Scenarios to test cases, capturing per-scenario evidence, or deciding a release verdict.

## What QA does
- Each PO acceptance criterion is a validation rule → a test.
  - **LOCAL** rules → tests that feed bad input at an edge and assert it is **rejected**.
  - **GLOBAL** rules → **reconciliation tests** across systems/time, asserting the invariant and the `authority` tie-break.
- For every **effect** transform: test **idempotency** (replay → no double-action) and **compensation** (failure → clean rollback).
- Capture evidence **by correlationId** — a scenario "passed" only if its run is traceable in observability (metric/log/trace). **Observation, not assertion.**

## The holdout = the anti-Goodhart firewall
QA holds the **held-back acceptance suite** — the cases the Developer agent never saw. Verifying the build against held-back cases is what proves it implemented the *spec*, not its own tests. Never hand the holdout to the builder.

## Pre-test gate (the eyes must work first)
Before running scenarios, confirm the **Observability Surface** renders live data and the `$correlationId` query resolves (see `df-observability`). Broken eyes block the verdict — evidence capture is impossible without them.

## Instructions
1. **Map, don't invent** — every test case starts from a PO scenario (one scenario → ≥1 case).
2. Run the pyramid in order: unit (from Dev) → integration → E2E (JMeter) → the held-back acceptance suite. Stop at the first quality-gate breach.
3. Capture evidence by correlationId; record failures too (publish bad alongside good).
4. **Verdict:** Pass / Conditional / Fail. A "pass" with no observability evidence is not earned. Route a Fail to the owning lane (code → Developer, deploy → Infra, requirement → PO).
5. **In-lane or out-of-lane — decide before the Fail blocks the verdict.** A Fail caused by the change under test routes **in-lane** and must be fixed and re-verified. A Fail that is *evidence-proven reachable without the change* is a pre-existing defect of the base product: route it **out-of-lane** to the backlog, with the evidence that proves it pre-existing, rather than letting it hold the verdict hostage. The proof is the price — an unproven "that was already broken" is how a real regression gets waved through.

## Don't
- Don't accept "done / tests pass" as the verdict — demand independent, unforgeable evidence.
- Don't skip the holdout (the dark-factory regression + anti-Goodhart guard).
- Don't auto-promote past the human gate in regulated (HIPAA) contexts.
