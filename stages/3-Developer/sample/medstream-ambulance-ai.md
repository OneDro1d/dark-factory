---
title: Per-Service Build Spec — vitals-classifier (MedStream, condensed sample)
stage: 3. Developer
type: per-service-build-spec
status: sample
---

# vitals-classifier — Build Spec (sample)

> Condensed example of the must-have Developer output: one service's Build Spec for the fictional MedStream product. (A real package has one of these per service.)

## TL;DR

`vitals-classifier` consumes raw ambulance vitals events, validates and classifies them (stroke-screen completeness, vitals plausibility), and publishes classified events for the summary-builder. Single responsibility: classification — nothing else.

## Anatomy deltas

| Component | Default | This service |
|---|---|---|
| Health | `:8080/healthz` | default |
| Metrics | `:9090/metrics` | + labels `vitals_type`, `classification`, `confidence` |
| Language | Go + the shared messaging library | Go (multi-arch) |
| DLQ | single-requeue → DLQ | bindings `vitals.dlq`, replay via `medstream-ctl` |

## Message contracts

| Direction | Exchange / key | Avro schema | Notes |
|---|---|---|---|
| consume | `medstream.ingest` / `vitals.raw` | `internal/models/vitals_raw.avsc` | from intake-api |
| publish | `medstream.classified` / `vitals.classified` | `internal/models/vitals_classified.avsc` | to summary-builder |

Idempotency: dedupe on `(transportId, eventSeq)` — **the resync-duplicate defect (TS-02) lives here.**

## Data this service owns

Stateless. Holds no persistence; classification logic lives in-service (Pattern 6). PHI passes through in-memory only; correlationId = `transportId`.

## Quick commands

```bash
make build
make test
make run-local
go run ./cmd/vitals-classifier --smoke   # publishes one classified event from a fixture
```

## Test expectations

| Level | What | Source |
|---|---|---|
| unit | stroke-screen completeness, plausibility bounds | this spec |
| integration | raw → classified round-trip via RabbitMQ | SA message flow MF-02 |
| E2E touchpoint | TS-02 (no duplicates on resync) | PO test scenarios |

## Build status

- [x] Skeleton forked
- [x] Contracts implemented
- [ ] Anatomy complete (idempotency dedupe missing — TS-02 fails)
- [ ] Tests green
- [ ] Adversary Developer: Pass

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Known defect (MED-114)

On connectivity resync, intake-api re-sends events; this service does not dedupe on `(transportId, eventSeq)`, so duplicates reach summary-builder. Fix: idempotency key check before publish. This is a code-lane fix — the SA Data Model already specifies the dedupe key, so no loop-back needed.
