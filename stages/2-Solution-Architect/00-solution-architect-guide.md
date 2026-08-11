---
title: Solution Architect (How?) — Stage Guide
stage: 2. Solution Architect
type: stage-guide
status: living
consumes: PO Vision + Requirements + Test Scenarios
produces: Data Model, Data Flow, Service Map
---

# Solution Architect (How?) — Stage Guide

## TL;DR

The Solution Architect turns the PO package into a buildable, deployable architecture by answering **how**. It produces **three must-have docs: Data Model, Data Flow, and Service Map.** Everything else the old SA stage emitted (deployment guide, test strategy, runbook, standalone observability) is **redistributed to the stage that owns it** — the SA leans on the shared platform non-negotiables in [`reference/`](../../reference/) instead of re-specifying them. The SA feeds **two parallel lanes** — Developer and Infrastructure Architect — that consume the same three docs independently.

## Where this stage sits

`Product Owner → **Solution Architect** → [ Developer ∥ Infrastructure Architect ] → QA → …`

## Inputs (must arrive from the PO package)

| Input | From PO | Why the SA needs it |
|---|---|---|
| **Vision** | PO (1) | Context: why/what/who, non-goals — bounds the design |
| **Requirements** | PO (1) | The capabilities + acceptance criteria to satisfy |
| **Test Scenarios** | PO (1) | Real-life flows that every data path must support |

## Must-have outputs (the small list)

| Output | Purpose | Template |
|---|---|---|
| **Data Model** | Entities, ownership, PHI/PII class, retention, **+ Avro message contracts** (what each service consumes/publishes) | [`templates/data-model-template.md`](templates/data-model-template.md) |
| **Data Flow** | End-to-end: what comes **in** → how it's **transformed** → where it's **stored** → what comes **out**, one path per PO scenario | [`templates/data-flow-template.md`](templates/data-flow-template.md) |
| **Service Map** | Every service: responsibility, ports, language, sidecar?, AMQP-vs-HTTP topology, anatomy/trust/observability **deltas**, operational knobs, **+ the Observability Surface** (required dashboards/queries keyed to PO scenarios — see below) | [`templates/service-map-template.md`](templates/service-map-template.md) |

These three carry everything the Developer lane needs to build and the Infrastructure lane needs to deploy. Platform boilerplate (microservices, AMQP bus, telemetry *emission*, DTAP, service anatomy) is **referenced, not restated** — the Service Map records only per-service deltas from the platform default.

> **Observability is a deliverable, not a delta.** The *Emit* leg (per-service `:9090/metrics`, correlationId logs — [`reference/service-anatomy.md`](../../reference/service-anatomy.md)) is platform default and stays "deltas only." But the **Observability Surface** — the dashboards + queryable log/trace views the downstream agents actually *look at* — is product-specific and must be **named here**: which dashboards/panels exist (flow/saga, throughput, tiered failure log, `$correlationId` trace, DLQ/queue depth, latency, health) and which PO scenario each flow panel maps to. These are the **eyes** QA and Ops use; without them, QA cannot capture per-scenario evidence and the verdict is unverifiable. Standard: [`reference/observability-standard.md`](../../reference/observability-standard.md).

## Optional outputs

- **ADRs** — one per *deviation* from a Prime Directive or the 8 patterns (not for choices already covered by the platform default)
- **Per-service CLAUDE.md seed** — bootstraps the Developer lane (Developer completes it)
- **Traceability matrix** — PO requirement → architecture element (lightweight; the Data Flow already traces scenarios)

## Exit gate

> **Cold Developer test:** Can a fresh Developer build every service from the Service Map + Data Model + Data Flow alone — no re-derivation, no invented contracts, no reading another project's code?
>
> **Cold Infra test:** Can a fresh Infrastructure Architect deploy across DTAP from the same three docs — no invented topology, no guessed trust boundaries?
>
> **Coverage + Directives:** Does every PO test scenario have a Data Flow path? Can you point to where each of the 10 Prime Directives is honoured (or an ADR for each deviation)?
>
> **Observability (the eyes):** Does the Service Map name the Observability Surface — the required dashboards/queries ([`reference/observability-standard.md`](../../reference/observability-standard.md) baseline) — with each flow/saga panel mapped to a PO scenario? An architecture whose scenarios have no dashboard to observe them violates Directive 1 and leaves QA blind.
>
> **Two-Lane test:** Can Developer and Infra each start independently? If a doc forces one to wait on the other, the boundary is wrong.
>
> **Org NFR overlay (optional, org-supplied):** where an organisation binds an NFR checklist,
> every applicable row is answered in the must-have docs (or marked `OUT-OF-SCOPE — <reason>` and
> accepted by the Adversary SA), and the filled checklist ships in the SA handoff as the
> design-review input. The overlay is **Tier-2 content** and lives in the organisation's own
> repo — this tier defines only the hook.

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Through the data-transform lens

See [`reference/data-transform-model.md`](../../reference/data-transform-model.md). The three must-have docs **are** the model:

- **Data Model = data nodes** — each entity's schema + single-datum invariants + context (`location`, `origin`, `authority`, `governance`). Declare the `authority` (system-of-record) for every fact that exists in more than one place.
- **Data Flow = the transform graph** — each step `(state, in) → (state', out)`, tagged `pure | effect`. Every `effect` (external write, publish, call, charge, notify) carries an **idempotency key + compensation** in the flow; every ingress edge lists the **LOCAL validation rules** applied before a datum is consumed.
- **Service Map = transform ownership + boundaries** — each service is a unit; its edges are trust boundaries (untrusted-until-validated, non-transitive). The runtime trust profile is just the `origin`/`authority`/boundary tags made explicit.
- Cross-system invariants (the PO's `GLOBAL` rules) become reconciliation paths, each with a named `authority` to resolve conflicts.

## Ownership handoff (PO → SA)

The PO + SMEs already defined the **semantics** (data, `origin`, `trust`, `authority`, `governance`, and the validation-rule predicates). Your job is **formalization**: turn each into a schema / Avro contract; assign every validation rule its enforcement **locus** (`LOCAL` → reject at an edge; `GLOBAL` → reconcile by `authority`) and **mechanism** (XSD / Schematron / DB constraint / reconciliation job); and tag transforms `pure`/`effect` with idempotency + compensation. Do **not** re-decide domain facts (which source is authoritative, what must be true) — if one is missing or wrong, loop back to PO rather than inventing it.

## Interaction mode

**Human-AI, interactive, iterative** (same as PO). The human SA owns boundaries and trade-offs; the AI drafts the three docs, audits against the Prime Directives, and flags deviations. Downstream lanes (Developer, Infra) are AI-supervised — so the three docs must be precise enough to drive an agent, not just inform a human.

## How the 18-output SA collapsed to 3

| Old SA output | Now lives in |
|---|---|
| Architecture Overview | Service Map TL;DR |
| Service Catalogue, Microservices Architecture, HTTP-vs-AMQP map, Runtime Trust, Observability spec, Operational knobs | **Service Map** (as per-service rows + deltas) |
| Data Architecture | **Data Model** |
| Message Flows, Data Flow Overview | **Data Flow** |
| Deployment Guide, Local Dev Setup | Infrastructure Architect stage (4) |
| Test Strategy | QA stage (5) |
| Per-service CLAUDE.md | Developer stage (3) — SA may seed it (optional) |
| Glossary, ADRs, Traceability | optional / folded into the three docs |

The redistribution is the whole point: each artifact lives with the stage that *owns* it, so no stage re-documents another's job.

## Workflow

1. **Decompose** the requirements into single-responsibility services (Pattern 1). If a service needs "and" to describe it, split it.
2. **Draft the Data Model** — entities, ownership (one owner per domain, Pattern 6), PHI/PII class, retention, and the Avro message contracts between services.
3. **Draw the Data Flow** — one path per PO scenario: in → transform → store → out. Pub/sub by default (Directive 3), async-first (Directive 4); every sync hop gets an ADR.
4. **Fill the Service Map** — per service: ports, language, sidecar?, consume/publish, anatomy deltas, trust deltas, knobs. Reference the platform defaults; record only deltas.
5. **Name the Observability Surface** — the required dashboards/queries ([`reference/observability-standard.md`](../../reference/observability-standard.md) baseline: flow/saga, throughput, tiered failure log, `$correlationId` trace, DLQ/queue depth, latency, health), each flow panel mapped to a PO scenario; plus the product-specific alerts + SLOs. This is what Infra builds and QA verifies.
6. **Audit against the 10 Prime Directives**; write an ADR for every deviation.
7. **Submit to Adversary SA review.**

## Handoff (two parallel manifests, pointers not copies)

- **Developer lane:** Service Map + Data Model + Data Flow (+ seed CLAUDE.md). Read order: Service Map → Data Model → Data Flow → `reference/` patterns.
- **Infrastructure lane:** Service Map + Data Model (+ trust deltas + the **Observability Surface** to build and verify). Read order: Service Map → Data Model.

## Failure modes

- Re-specifying platform boilerplate instead of referencing it (the old 18-doc noise).
- Sync-everywhere because pub/sub felt heavy (Directive 3/4 violation, no ADR).
- A PO scenario with no Data Flow path (the system won't support real work).
- Service Map rows that omit the deltas a lane actually needs (forces guessing → cold-test fail).
- A handoff that couples the two lanes sequentially.

## References

- [`reference/data-transform-model.md`](../../reference/data-transform-model.md) — the lens: Data Model = data nodes · Data Flow = transform graph (`pure | effect`) · Service Map = transform ownership + boundaries
- [`reference/10-prime-directives.md`](../../reference/10-prime-directives.md) · [`reference/8-implementation-patterns.md`](../../reference/8-implementation-patterns.md) · [`reference/service-anatomy.md`](../../reference/service-anatomy.md)
- [`reference/observability-standard.md`](../../reference/observability-standard.md) — the eyes: the Observability Surface (dashboards/queries) the SA must name, Infra builds, QA verifies
- [`01-adversary-solution-architect.md`](01-adversary-solution-architect.md)
