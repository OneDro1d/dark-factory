---
title: Service Map — <Product Name>
stage: 2. Solution Architect
type: service-map
status: template
consumes: PO requirements, Data Model, Data Flow
---

# Service Map — <Product Name>

## TL;DR

<One paragraph + a one-line list of services: the architecture overview in miniature. This replaces the old standalone Architecture Overview.>

## Services

The dense table both downstream lanes read first. Platform defaults from [`reference/service-anatomy.md`](../../../reference/service-anatomy.md); record **deltas only**.

| Service | Responsibility (one thing) | Lang | Ports | Sidecar? | Consumes | Publishes | Anatomy deltas |
|---|---|---|---|---|---|---|---|
| `<service>` | <single responsibility> | Go/.NET | 8080/9090 | no | `<key>` | `<key>` | <e.g. extra metric labels> |

## HTTP vs AMQP map

| Path | Protocol | Sync? | ADR (if sync) |
|---|---|---|---|
| client → intake | HTTP (edge, 202) | n/a | — |
| intake → classifier | AMQP | no | — |
| `<a> → <b>` | <HTTP/AMQP> | <yes/no> | <ADR> |

Internal = AMQP by default; HTTP only at the edge (anti-pattern: protocol leaking past the edge).

## Per-service trust deltas (Directive 9)

| Service | Identity | Scopes | Data class | Revocation |
|---|---|---|---|---|
| `<service>` | <sa> | <read/write/call> | PHI/PII/public | <path> |

## Per-service operational knobs (Directive 10)

| Service | Slow | Stop | Redirect | Inspect |
|---|---|---|---|---|
| `<service>` | <mechanism> | <mechanism> | <mechanism> | <mechanism> |

Infra (4) provisions these; Operations (6) turns them.

## Alerts & SLOs (per service — must-have, not boilerplate)

The SA owns the **product-specific** alert conditions and SLOs — Ops builds its alert→response playbook from this table and Directive 6 (no customer-first failure) depends on it. Platform-default alerts (DLQ depth, health-down) are assumed; name the **product** ones here.

| Service | Alert condition | SLO | Maps to PO scenario |
|---|---|---|---|
| `<service>` | `<metric > threshold over window>` | `<target>` | `<TS-0x>` |

## Observability Surface — the eyes (must-have, not a delta)

The dashboards + queryable views the downstream agents *look at* to confirm work happened. Telemetry **emission** is platform default ([`reference/service-anatomy.md`](../../../reference/service-anatomy.md)); this surface is **product-specific** and is what Infra builds + QA verifies. Baseline + acceptance bar: [`reference/observability-standard.md`](../../../reference/observability-standard.md).

| Required view | What it shows for THIS product | Maps to PO scenario(s) |
|---|---|---|
| Flow / saga | <which states a request moves through; completed/deferred/failed counts> | `<TS-0x …>` |
| Throughput | <per-service + per-exchange msg/s> | all |
| Tiered failure log | <errors/warns by `level` field, key services> | `<TS-0x>` |
| `$correlationId` trace | <one request across all services> | all |
| DLQ + queue depth | <which queues/DLQs> | — |
| Latency p50/p95/p99 | <per service + end-to-end sync edges> | `<TS-0x>` (SLO gate) |
| System health | <pods, restarts, scrape-up> | — |

> A product with sagas/long-running workflows **must** ship the Flow/saga view. A pure request/response product may fold it into Throughput + `$correlationId` and note that here — silent omission is a Fail.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Prime Directive audit

| # | Directive | Honoured where | ADR if deviated |
|---|---|---|---|
| 1 | Nothing unwatched | every service `:9090/metrics` + alerts + the Observability Surface (dashboards/queries) | — |
| 3 | Pub/sub default | HTTP-vs-AMQP map | — |
| 4 | Async default | Data Flow sync-hop table | <ADR> |
| 8 | Bulkheading | per-service DLQ + ≥3 replicas | — |
| 9 | Runtime trust | trust-deltas table | — |
| 10 | Ops knobs | knobs table | — |

(Complete all 10; see [`reference/10-prime-directives.md`](../../../reference/10-prime-directives.md).)

## Observability deltas (emission only)

Per service, anything beyond the Service Anatomy default (custom metric names, extra labels) the Developer must emit so the Observability Surface above can render. Emission default is assumed; record deltas only. The *surface* (dashboards/queries) is the must-have section above, not a delta — Infra builds it, QA verifies it renders live data.

## Handoff read-order

- Developer: this map → Data Model → Data Flow → `reference/` patterns.
- Infrastructure: this map → `reference/dtap` → Data Model.
