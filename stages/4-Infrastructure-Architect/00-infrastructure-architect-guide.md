---
title: Infrastructure Architect (Where?) — Stage Guide
stage: 4. Infrastructure Architect
type: stage-guide
status: living
consumes: SA service map + data model + runtime trust + observability deltas
produces: Deployment & Infrastructure Spec
---

# Infrastructure Architect (Where?) — Stage Guide

## TL;DR

The Infrastructure Architect decides **where** the architecture runs and makes it deployable across all environments (Dev → Test → Acceptance → Production). It produces **one must-have doc: the Deployment & Infrastructure Spec** — clusters, secrets, network, storage, observability sinks, trust enforcement, and the wired operational knobs. It runs in **parallel with the Developer lane** (both consume the SA package; neither waits on the other).

## Where this stage sits

`Solution Architect → [ Developer ∥ **Infrastructure Architect** ] → QA → … → Operations`

## Inputs (must arrive from upstream — the SA package)

| Input | From SA | Why Infra needs it |
|---|---|---|
| **Service Map** | SA (2) | Every service to deploy: ports, language, sidecar?, AMQP topology |
| **Data Model** | SA (2) | What persists, where, PHI/PII posture → storage + compliance |
| Runtime trust deltas | SA (2) | Secrets, IAM, revocation per service (Directive 9) |
| Observability Surface + deltas | SA (2) | The dashboards/queries to **build and verify** + which sinks/alerts to provision (Directive 1) |
| Operational knobs | SA (2) | What to wire so Ops can slow/stop/redirect/inspect (Directive 10) |

Most of the *how* is platform boilerplate — the standard environment progression (Dev → Test → Acceptance → Production) and a base+overlays deployment layout. The Infra spec records only the **per-product deltas** on top of that.

## Must-have output (the small list)

| Output | Purpose | Template |
|---|---|---|
| **Deployment & Infrastructure Spec** | environment overlays · cluster table · secrets · network · storage · observability sinks **+ dashboards-as-code verified rendering live data** · trust enforcement · knob provisioning · deploy procedure | [`templates/deployment-infrastructure-spec-template.md`](templates/deployment-infrastructure-spec-template.md) |

## Optional outputs

- Per-cluster runbook deltas (feed Operations)
- Cost / capacity model

## Exit gate

> **Cold Infra → downstream test:** From the SA package + this spec, can QA stand the system up and Operations run it — every service has a Kustomize overlay, every secret a source + rotation, every alert a sink, every knob a provisioning step — without inventing topology or guessing trust boundaries?

> **Eyes-on test (the observability surface works):** Is every SA-named dashboard built as code and **verified rendering live data**, the `$correlationId` query resolving across services, and every alert rule evaluating (not "no data")? If QA would open the dashboards and see "No data", the eyes don't work and the spec is not done — QA cannot capture scenario evidence. Bar: [`reference/observability-standard.md`](../../reference/observability-standard.md).

> **Two-Lane test:** Could this lane finish without waiting on the Developer lane, and vice versa? If the spec implies a sequential dependency on built code, the boundary is wrong.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Through the data-transform lens

See [`reference/data-transform-model.md`](../../reference/data-transform-model.md). Infra places the **data nodes and draws the boundaries**:

- `location` per data node → storage class, region, residency. The `governance` tag (PHI/PII, residency) is enforced by *where* you put the data.
- Every unit edge is a **trust boundary**: "inside the cluster is trusted" is the sticky-trust anti-pattern (Directive 5). Provision so each ingress can validate; secrets/IAM enforce the boundary, not network position.
- Wire the knobs the GLOBAL **reconciliation** loops and effect **compensation** paths need in order to run in Operations.

## Interaction mode

**AI, supervised by humans.** Provisioning manifests are AI-authored; applying them to shared-dev or production clusters is a human-gated action (and a production change requires a ticket + announcement per platform rules).

## Workflow

1. **Start from the platform's standard environment progression** (Dev → Test → Acceptance → Production), not a blank page. The per-environment clusters and the base+overlays layout are platform-standard.
2. **Per service, record deltas only:** which overlay specifics (arch, registry, secrets source), storage class, ingress/egress posture. Default to the standard; document exceptions with an ADR pointer.
3. **Map every SA runtime-trust entry** to an enforcement mechanism: IRSA/IAM (EKS), sealed-secrets (on-prem), network policy, DB roles.
4. **Build the Observability Surface, don't just provision sinks.** Wire each SA observability entry to a sink (Prometheus, Loki, OTel collector, Alertmanager, Grafana) **and** ship the SA-named dashboards **as code** (`deployments/grafana/…`, like Fulcrum's `grafana-dashboards/`) + datasources, then **verify every required view renders live data** and the `$correlationId` query resolves across services — the acceptance bar in [`reference/observability-standard.md`](../../reference/observability-standard.md). A dashboard that shows "No data" is not delivered.
5. **Provision every SA operational knob** so Operations can actually turn it (the Ops Runbook will reference these).
6. **Write the deploy procedure** QA follows to stand the system up.

## Handoff

To **QA**: the deploy procedure + a deployable system + **the verified Observability Surface** (dashboard URLs that render live data — QA's evidence source). To **Operations** (via QA Pass): the dashboards/queries, observability sinks, secret/rotation posture, and wired knobs that the Operations Runbook consumes. This lane does **not** hand off to Developer — they are parallel.

## Failure modes

- Re-specifying the whole platform deployment model instead of recording deltas (noise; drift from the platform standard).
- A secret with no source or rotation policy.
- An SA-designed knob never provisioned (Ops finds out at 3am).
- Implicit trust ("inside the cluster is trusted") — Directive 5 violation.
- A hidden ordering dependency on the Developer lane — breaks the parallel fork.

## References

- [`reference/data-transform-model.md`](../../reference/data-transform-model.md) — the lens: place data nodes + enforce trust boundaries; `location` enforces `governance`
- [`reference/service-anatomy.md`](../../reference/service-anatomy.md) — health/metrics/config surfaces to wire
- [`reference/observability-standard.md`](../../reference/observability-standard.md) — the eyes Infra builds + verifies: dashboards-as-code + the "rendering live data" acceptance bar
- [`reference/10-prime-directives.md`](../../reference/10-prime-directives.md) — Directives 5, 8, 9, 10
- [`01-adversary-infrastructure-architect.md`](01-adversary-infrastructure-architect.md)
