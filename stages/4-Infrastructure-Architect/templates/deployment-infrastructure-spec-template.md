---
title: Deployment & Infrastructure Spec — <Product Name>
stage: 4. Infrastructure Architect
type: deployment-infrastructure-spec
status: template
consumes: SA service map, data model, runtime trust, observability, operational knobs
---

# Deployment & Infrastructure Spec — <Product Name>

## TL;DR

<One paragraph: where this system runs (which clusters, prod target), and the one infra constraint that matters most (e.g. PHI residency, multi-arch).>

## Cluster & overlay map

Record only what differs from the platform default (the standard Dev → Test → Acceptance → Production environment progression).

| Service | dev | test | acceptance | prod | Notes (deltas) |
|---|---|---|---|---|---|
| `<service>` | ✓ | ✓ | ✓ | ✓ | <e.g. amd64-only; external RabbitMQ> |

## Secrets

| Secret | Service | Source (on-prem / EKS) | Rotation |
|---|---|---|---|
| `<KEY>` | `<service>` | sealed-secret / AWS SM + IRSA | <cadence> |

## Network posture

- **Ingress:** which services are exposed; auth (Clerk SSO / mTLS / API key).
- **Internal:** AMQP only; any internal HTTP path is ADR-justified (cite the SA HTTP-vs-AMQP map).
- **Egress:** external partner calls; egress controls.

## Storage

| Service | Storage class | Size | Backup |
|---|---|---|---|
| `<service>` | EBS / local-path | <size> | <cadence + target> |

## Observability sinks (Directive 1)

| Layer | Tooling | Source |
|---|---|---|
| Metrics | Prometheus | `:9090/metrics` |
| Logs | Loki + Promtail | stdout |
| Traces | OTel collector → <backend> | TwistyGo `tracing.InjectAMQP` |
| Alerts | Alertmanager → <pager> | Prometheus rules |
| Dashboards | Grafana | `deployments/grafana/` |

## Observability Surface — built & verified (the eyes)

Sinks alone are not the eyes. Each SA-named dashboard ([Service Map → Observability Surface](../../2-Solution-Architect/templates/service-map-template.md)) is shipped **as code** and **verified rendering live data** before this spec passes. Bar: [`reference/observability-standard.md`](../../../reference/observability-standard.md).

| Required view | Built as code at | URL | Verified rendering live data? |
|---|---|---|---|
| Flow / saga | `deployments/grafana/<...>.json` | `<grafana>/d/<uid>` | ✓ / ✗ |
| Throughput | `…` | `…` | ✓ / ✗ |
| Tiered failure log | `…` | `…` | ✓ / ✗ |
| `$correlationId` trace | `…` | `…` | ✓ / ✗ |
| DLQ + queue depth | `…` | `…` | ✓ / ✗ |
| Latency p50/p95/p99 | `…` | `…` | ✓ / ✗ |
| System health | `…` | `…` | ✓ / ✗ |

> Acceptance: every required view renders live data (checked against the datasource proxy, not just schema-valid JSON), the `$correlationId` query resolves across services, and every alert rule evaluates (not "no data"). A dashboard showing "No data" — or pointed at the wrong cluster — is **not** delivered.

## Operational knobs provisioned (Directive 10)

For each SA-designed knob, the concrete mechanism Operations will use.

| Service | Slow | Stop | Redirect | Inspect |
|---|---|---|---|---|
| `<service>` | <rate-limit cfg> | <drain cmd> | <failover route> | <debug/replay tool> |

## Runtime trust enforcement (Directive 9)

| Service | Identity (SA/IRSA) | IAM/DB roles | Data class | Revocation |
|---|---|---|---|---|
| `<service>` | <sa> | <roles> | PHI/PII/public | <path> |

## Deploy procedure (for QA)

```text
1. kubectl apply -k overlays/<env>       # per environment, in order (dev -> test -> acceptance -> prod)
2. verify :8080/healthz on every service
3. confirm observability sinks receiving data
4. open every required dashboard; confirm each renders LIVE data + $correlationId query resolves (the eyes work)
5. hand QA the cluster + access + the dashboard URLs
```

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Compliance posture

HIPAA: encryption at rest + in transit, audit retention 6y, PHI segregation, Armarium/N-DIM audit for safety-grade decisions. FedRAMP-readiness: <yes/no + target>.

## What is NOT here

- Service implementation code → Developer lane.
- Test execution → QA. Runbook → Operations (this spec feeds it).

## Notes for the AI infra agent

- Applying to shared-dev or prod is human-gated and requires a ticket + channel announcement.
- Default to the standard environment progression; every deviation needs an ADR pointer.
