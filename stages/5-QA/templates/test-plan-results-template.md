---
title: Test Plan & Results — <Product Name>
stage: 5. QA
type: test-plan-results
status: template
consumes: PO test scenarios + definition of done, deployed system, observability
---

# Test Plan & Results — <Product Name>

## TL;DR

<One paragraph: what was tested, on which cluster, and the headline verdict.>

## Verdict

**<Pass | Conditional | Fail>** — <one-line justification tied to evidence>.

## Pre-test gate — the eyes work (run before scenarios)

The Observability Surface is QA's evidence source; verify it renders **before** testing. If any row is ✗, **halt and route to Infra (4)** — the verdict is blocked, not Fail-by-scenario, because evidence cannot be captured through a blind instrument. Bar: [`reference/observability-standard.md`](../../../reference/observability-standard.md).

| Eye | URL | Renders live data? |
|---|---|---|
| Flow / saga dashboard | `<grafana>/d/<uid>` | ✓ / ✗ |
| Throughput dashboard | `…` | ✓ / ✗ |
| Tiered failure log | `…` | ✓ / ✗ |
| `$correlationId` trace query (resolves across services) | `…` | ✓ / ✗ |
| DLQ + queue depth | `…` | ✓ / ✗ |
| Alert rules evaluating (not "no data") | `<alerting>` | ✓ / ✗ |

**Eyes verdict:** <WORKING → proceed | DARK → blocked, routed to Infra>.

## Scenario coverage (the core table)

One row per PO real-life scenario. No scenario may be missing.

| PO scenario | Test case | Type | Evidence (metric/log/trace) | Result |
|---|---|---|---|---|
| `<TS-01>` | <case> | E2E (JMeter) | correlationId `<id>` → `<metric>` | Pass/Fail |
| `<TS-02>` | <case> | integration | `<log line>` | Pass/Fail |

## Quality gates

| Gate | Threshold (from SA Test Strategy) | Actual | Pass? |
|---|---|---|---|
| Unit coverage | <e.g. ≥80%> | <x%> | |
| E2E pass rate | 100% of must-have scenarios | <x%> | |
| p95 latency | <target> | <actual> | |

## Failures & open items

<List every failure honestly. For each: scenario, what broke, owning lane, ticket.>

## Definition of Done (from PO)

<Restate the PO definition-of-done and check each item.>

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## How each scenario was exercised

Per scenario: the JMeter plan / test harness, the cluster, the input fixtures, and the correlationId used to pull evidence from observability.

## Routing on Fail

| Failure class | Owning lane |
|---|---|
| Service logic / contract bug | Developer (3) |
| Deploy / topology / secrets | Infrastructure Architect (4) |
| Wrong or ambiguous requirement | Product Owner (1) |

## Handoff on Pass

Deployed system + JMeter plans + observability evidence → Operations. Verdict → PO Final Sign-off.
