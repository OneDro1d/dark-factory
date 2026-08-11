---
title: Test Plan & Results — MedStream Ambulance AI (condensed sample)
stage: 5. QA
type: test-plan-results
status: sample
---

# Test Plan & Results — MedStream Ambulance AI (sample)

> Condensed example of the must-have QA output for the fictional MedStream product.

## TL;DR

Ran the three must-have PO scenarios against `eks-dev02`. Two pass with trace evidence; the resync-deduplication scenario fails — duplicate vitals events on connectivity recovery. **Verdict: Fail**, routed to Developer (idempotency bug on the resync path).

## Verdict

**Fail** — TS-02 (no duplicates after connectivity drop) produced 3 duplicate events; defect filed to Developer lane (MED-114).

## Scenario coverage

| PO scenario | Test case | Type | Evidence | Result |
|---|---|---|---|---|
| TS-01 paramedic streams stroke patient | stream 50 vitals events, assert ack <500ms | E2E (JMeter) | correlationId `ts01-*` → `intake_ack_seconds p95=0.41` | **Pass** |
| TS-02 connectivity drops then resumes, no dupes | drop network 30s mid-stream, resume | E2E (JMeter) | correlationId `ts02-*` → `dedupe_miss_total=3` | **Fail** |
| TS-03 hospital sees pre-arrival summary | full transport sim, assert summary before arrival | E2E (JMeter) | correlationId `ts03-*` → `summary_delivered_before_arrival=1` | **Pass** |

## Quality gates

| Gate | Threshold | Actual | Pass? |
|---|---|---|---|
| Unit coverage | ≥80% | 84% | ✓ |
| E2E must-have pass rate | 100% | 67% (2/3) | ✗ |
| Intake p95 latency | <500ms | 410ms | ✓ |

## Failures & open items

- **TS-02 duplicates** — on resync, the same vitals events re-publish without idempotency-key dedup. Owning lane: Developer. Ticket: MED-114.

## Definition of Done (from PO)

- [x] Vitals stream to cloud with <500ms ack
- [ ] No duplicate events after connectivity loss ← blocking
- [x] Pre-arrival summary delivered before arrival

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Routing on Fail

TS-02 is a service-logic defect (missing idempotency on resync) → Developer (3), MED-114. Not a deploy or requirement issue.

## Handoff

Blocked until MED-114 fixed and TS-02 re-run green. On Pass, the verified system + JMeter plans + traces move to Operations.
