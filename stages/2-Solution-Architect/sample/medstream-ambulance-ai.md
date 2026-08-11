---
title: Solution Architecture — MedStream Ambulance AI (condensed sample)
stage: 2. Solution Architect
type: sa-package
status: sample
---

# Solution Architecture — MedStream Ambulance AI (sample)

> Condensed end-to-end SA package: the three must-have docs (Data Model · Data Flow · Service Map) for the fictional MedStream product, in one file.

---

## 1. Data Model

### Entities

| Entity | Purpose | Owner | Cardinality | Class | Retention |
|---|---|---|---|---|---|
| VitalsEvent | one vitals reading | vitals-classifier (transient) | N per transport | PHI | not stored raw |
| Transport | one ambulance run | summary-builder | 1 | PHI | 7y |
| PreArrivalSummary | ML summary for hospital | summary-builder | 1 per transport | PHI | 7y |

### Invariants

- A VitalsEvent is deduped on `(transportId, eventSeq)` — reprocessing is safe.
- No service reads another's store; summary-builder owns the only DB.

### Message contracts (Avro)

| Producer | Consumer | Exchange / key | Schema | Key fields |
|---|---|---|---|---|
| intake-api | vitals-classifier | `medstream.ingest` / `vitals.raw` | `vitals_raw.avsc` | transportId, eventSeq, vitals |
| vitals-classifier | summary-builder | `medstream.classified` / `vitals.classified` | `vitals_classified.avsc` | transportId, classification, confidence |
| summary-builder | handoff-notifier | `medstream.summary` / `summary.ready` | `summary_ready.avsc` | transportId, hospitalId, summary |

### Persistence

| Store | Owner | Engine | PHI | Encryption |
|---|---|---|---|---|
| medstream-db | summary-builder | Postgres | yes | at-rest (KMS) + TLS |

---

## 2. Data Flow

```text
ambulance --HTTP 202--> [intake-api] --AMQP vitals.raw--> [vitals-classifier]
   --AMQP vitals.classified--> [summary-builder] --store--> [medstream-db]
                                      \--AMQP summary.ready--> [handoff-notifier] --FHIR--> hospital
```

| Scenario | In | Transform | Store | Out | Sync hops |
|---|---|---|---|---|---|
| TS-01 stream stroke patient | vitals stream | intake → classifier | — | ack 202 | none |
| TS-02 connectivity drop/resume | re-sent vitals | classifier dedupe `(transportId,eventSeq)` | — | no dupes | none |
| TS-03 pre-arrival summary | full transport | classifier → summary-builder | medstream-db | summary to hospital | none |

All inter-service hops are AMQP — no sync ADRs needed. Edge is HTTP 202 (async-first).

---

## 3. Service Map

MedStream = 4 services: intake-api, vitals-classifier, summary-builder, handoff-notifier.

| Service | Responsibility | Lang | Ports | Sidecar | Consumes | Publishes | Deltas |
|---|---|---|---|---|---|---|---|
| intake-api | accept + 202 ambulance streams | Go | 8080/9090 | no | — (HTTP) | vitals.raw | mTLS client certs |
| vitals-classifier | classify + dedupe vitals | Go | 8080/9090 | no | vitals.raw | vitals.classified | labels vitals_type, confidence |
| summary-builder | ML pre-arrival summary | Go | 8080/9090 | no | vitals.classified | summary.ready | GPU node; owns medstream-db |
| handoff-notifier | push summary to hospital | Go | 8080/9090 | no | summary.ready | — (FHIR egress) | egress allow-list |

### HTTP vs AMQP

| Path | Protocol | Sync? |
|---|---|---|
| ambulance → intake | HTTP 202 (edge) | n/a |
| all inter-service | AMQP | no |
| handoff → hospital FHIR | HTTPS (egress edge) | yes (ADR-MED-02: external partner API) |

### Trust deltas

| Service | Identity | Scopes | Class | Revocation |
|---|---|---|---|---|
| handoff-notifier | IRSA medstream-handoff | FHIR egress only | PHI | disable SA + netpol |
| summary-builder | IRSA medstream-summary | DB + model bucket RO | PHI | disable SA |

### Operational knobs

| Service | Slow | Stop | Redirect | Inspect |
|---|---|---|---|---|
| intake-api | rate cfg | pause | standby region | log stream |
| summary-builder | HPA cap | pause | n/a | dlq-replay |
| handoff-notifier | — | drain | backup hospital (**human**) | replay DLQ |

### Alerts & SLOs

| Service | Alert | SLO | PO scenario |
|---|---|---|---|
| summary-builder | `summary_late` (summary after arrival > 5% / 10m) | 99% before arrival | TS-03 |
| vitals-classifier | `dup_events` (any duplicate after resync) | 0 duplicates | TS-02 |
| intake-api | `intake_5xx` (> 1% 5xx) | 99.9% availability | TS-01 |

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Prime Directive audit (excerpt)

| # | Directive | Honoured where | ADR |
|---|---|---|---|
| 1 | Nothing unwatched | all 4 services metrics + 3 alerts | — |
| 3/4 | Pub/sub + async | all inter-service AMQP; edge 202 | — |
| 8 | Bulkheading | per-service DLQ, ≥3 replicas | — |
| 9 | Runtime trust | trust-deltas table | — |
| 2 (sync) | handoff → FHIR is sync | external partner | ADR-MED-02 |

## ADRs (deviations only)

- **ADR-MED-02** — handoff → hospital FHIR is synchronous HTTPS (external partner API has no async option); contained by 5s timeout + circuit breaker + DLQ-on-fail.
- **ADR-MED-04** — summary-builder is EKS/GPU-only, breaking multi-arch parity (ML model needs GPU).

## Handoff

- Developer lane: Service Map → Data Model → Data Flow → `reference/` patterns.
- Infrastructure lane: Service Map → `reference/dtap` → Data Model.
