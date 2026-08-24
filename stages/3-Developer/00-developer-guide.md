---
title: Developer (Builds code) — Stage Guide
stage: 3. Developer
type: stage-guide
status: living
consumes: SA service map + data model + Avro message contracts + data flow (+ seed per-service CLAUDE.md)
produces: working code + tests, governed by a Per-Service Build Spec per service
---

# Developer (Builds code) — Stage Guide

## TL;DR

The Developer lane builds each service's code and tests. Its travelling doc artifact is **one Per-Service Build Spec (CLAUDE.md) per service** — the primer that boots a cold AI developer and stays accurate as the code is written. It runs **in parallel with the Infrastructure Architect lane**; both consume the SA package, neither waits on the other. Real output = green code + passing tests, **built test-first** — TDD (RED→GREEN→REFACTOR) is the **recommended default** for this stage; see [`02-tdd-implementation-guide.md`](02-tdd-implementation-guide.md) (and [`03-why-we-test-first.md`](03-why-we-test-first.md) for the rationale).

## Where this stage sits

`Solution Architect → [ **Developer** ∥ Infrastructure Architect ] → QA → …`

## Inputs (must arrive from upstream — the SA package)

| Input | From SA | Why the Developer needs it |
|---|---|---|
| **Service Map** | SA (2) | Boundaries, responsibilities, ports, sidecar?, AMQP topology |
| **Data Model + message contracts** | SA (2) | Avro schemas, what each service consumes/publishes |
| **Data Flow** | SA (2) | In → transform → store → out, so the code does the right work |
| Seed per-service CLAUDE.md | SA (2), optional | Starting primer; the Developer completes it |
| Patterns + anatomy | `reference/` | The 8 patterns + Service Anatomy are the build defaults |

## Must-have output (the small list)

| Output | Purpose | Template |
|---|---|---|
| **Per-Service Build Spec (CLAUDE.md)** | One per service: primes a cold AI dev, records anatomy deltas, message contracts, quick commands, test + build status. Travels with the code. | [`templates/per-service-build-spec-template.md`](templates/per-service-build-spec-template.md) |

Code + tests are the actual deliverable; the Build Spec is how the factory keeps a service buildable and re-bootable.

## Optional outputs

- Local development setup notes (if the SA local-dev hints are insufficient)

## Exit gate

> **Cold AI-dev test:** Can a fresh AI developer build each service from its Build Spec + the SA artifacts alone — without re-deriving requirements, inventing message contracts, or reading another project's code? Are all unit + integration tests green, and has the Adversary Developer returned Pass?

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Through the data-transform lens

See [`reference/data-transform-model.md`](../../reference/data-transform-model.md). The code **implements transforms**:

- Each handler is a transform `(state, in) → (state', out)`. **Validate at every ingress** (the LOCAL rules from the SA Data Flow) before consuming a datum — trust is re-earned per edge; never skip validation because a message came from your own bus.
- Every transform the SA tagged **effect** ships its **idempotency key** (retry ≠ double-action) and its **compensation**. If a step the SA marked `pure` actually writes externally, loop back to SA — don't silently turn it into an effect.
- Honour declared `authority`: never overwrite a system-of-record value with a local cached copy.

## Interaction mode

**AI, supervised by humans.** The AI developer writes the code and tests; humans review and approve merges. Pushing to a protected branch / merging is a hard-stop human action.

## Workflow

1. **Fork, don't redesign** (Pattern 7). Clone the standard service skeleton; infrastructure (the shared messaging library's init, metrics server, AMQP connect, DLQ) comes free. Write only the business logic.
2. **Honour the contracts.** Consume/publish exactly the Avro schemas in the SA Data Model. No private side channels (Directive 2).
3. **Build each transform test-first — the recommended default.** RED → GREEN → REFACTOR, one case at a time; the test list is the PO's validation rules + Test Scenarios for this service (full method + Go/Python examples in [`02-tdd-implementation-guide.md`](02-tdd-implementation-guide.md)). Apply the 8 patterns by default in the GREEN step; any deviation needs an ADR pointer (back to SA).
4. **Complete the Build Spec** as you go: anatomy deltas, quick commands, test status. Keep it true — it is validated by booting a fresh AI session against it.
5. **Tests green before handoff.** Every validation rule + PO scenario that touches this service has a test; every `effect` has idempotency + compensation tests; `go test ./... -race` / `pytest` all green. E2E + holdout belong to QA — don't duplicate them here.
6. **Submit to Adversary Developer review.**

## Handoff

To **QA**: the built services (deployed by the Infra lane), their tests, and the per-service metrics/logs/traces. This lane does **not** hand off to Infrastructure — they are parallel.

## Failure modes

- Custom AMQP code instead of the shared messaging library (anti-pattern).
- `Log.Error` (panics in this stack's shared messaging library) instead of `Log.Warn`.
- Build Spec that restates the architecture instead of priming a working agent (the Fulcrum CLAUDE.md is the bar: quick commands, real file paths, smoke test).
- Inventing a message contract the SA did not define — should be an SA loop-back, not a local decision.
- `latest` tags / 2 replicas (anti-patterns).

## References

- [`02-tdd-implementation-guide.md`](02-tdd-implementation-guide.md) — **how to build:** test-first (RED→GREEN→REFACTOR), with Go + Python examples; the test list = the PO's validation rules + scenarios
- [`03-why-we-test-first.md`](03-why-we-test-first.md) — **why** test-first, in plain language (RED/GREEN/REFACTOR explained for non-developers)
- [`reference/data-transform-model.md`](../../reference/data-transform-model.md) — the lens: handlers are transforms; validate every ingress; effects ship idempotency + compensation
- [`reference/8-implementation-patterns.md`](../../reference/8-implementation-patterns.md) — the build defaults (async-first 202, AMQP-only, config-over-code, fork-and-reuse, at-least-once+DLQ)
- [`reference/service-anatomy.md`](../../reference/service-anatomy.md) — what every service must include
- [`01-adversary-developer.md`](01-adversary-developer.md)
