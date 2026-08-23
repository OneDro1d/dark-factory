---
name: df-observability
description: 'Dark Factory Observability stage: make the consumable surface (dashboards and queryable traces keyed to scenarios, verified rendering live data) a named deliverable — a /metrics endpoint nobody can see is not observability. Triggers on "observability", "dashboards", "Grafana", "correlationId trace", "telemetry surface".'
---

# Dark Factory — Observability Standard (the agents' eyes)

## Overview
Observability is the **sensory apparatus the agents use to build, deploy, and test** — not optional garnish. Emitting telemetry is necessary but **not sufficient**: a `:9090/metrics` endpoint nobody can *see* is not observability. This standard makes the **consumable surface** a named, verified deliverable.

**Rule of thumb:** if an agent cannot answer *"did scenario TS-0x run, and where did it succeed or fail?"* by looking at a dashboard or running one query, the system is not observable yet — no matter how many metrics it emits.

## The three legs — Emit → Surface → Act
| Leg | Question | Owner | Artifact |
|---|---|---|---|
| **Emit** | Is telemetry produced? | Developer (service anatomy) | `:9090/metrics`, JSON logs w/ `correlationId`, `:8080/healthz`, DLQ depth |
| **Surface** | Can a human/agent *see and query* it? | **SA designs · Infra builds · QA verifies** | dashboards + queryable log/trace views that render live data (the historically missing leg) |
| **Act** | Does it fire before customers notice? | SA names · Infra wires | alerts → a sink |

Emission is platform default (deltas only). **Surface is product-specific and must be delivered + verified** — that is the gap this standard closes.

## Required baseline dashboard set (the floor)
Flow/saga (end-to-end path of each PO scenario) · Throughput · **Tiered failure log filtered by the log *level field* (`"level":"ERROR"`), not a substring `(?i)error`** (substring matching floods false positives from name collisions) · Correlation/trace lookup (a `$correlationId` variable pulling every log + span across services) · DLQ + queue depth · Latency (p50/p95/p99) · System health. Panels keyed to PO scenarios.

## The acceptance bar — "verified rendering live data"
A dashboard that POSTs valid JSON but shows "No data" is **not** delivered. Every view reachable at a known URL; every panel renders live data (against the datasource, not just schema-valid); `$correlationId` returns real cross-service results; every alert rule evaluates. **Verification is by observation, not assertion.**

## Anti-patterns
- **Emit-only** — `/metrics` exists, no dashboard renders it → QA can't capture evidence.
- **Schema-valid, no data** — dashboard JSON loads but every panel shows "No data".
- **Substring failure filters** — `(?i)error` instead of the level field.
- **Hand-clicked dashboards** — not in version control as code → lost on cluster rebuild.
- **Human-only access** — reachable by a human in prod, but the QA/Dev agent has no programmatic path in dev/test.
