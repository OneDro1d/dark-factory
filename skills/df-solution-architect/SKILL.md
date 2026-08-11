---
name: df-solution-architect
description: Dark Factory Solution Architect stage: turn PO semantics into a Data Model, Data Flow (transform graph, pure|effect, idempotency, compensation) and Service Map, assigning each validation rule an enforcement locus. Triggers on "architecture", "data model", "data flow", "service map", "schema", "Avro contract", "solution architect".
---

# Dark Factory — Solution Architect (formalize the transform graph)

## Overview
The SA answers **how**. It produces **Data Model, Data Flow, Service Map**. Through the data-transform lens (`df-data-transform-lens`), the three docs **are** the model. The PO already defined the semantics; the SA's job is **formalization** — turn each into a schema/contract, assign each rule its enforcement locus and mechanism, and tag transforms.

## The three outputs

- **Data Model = data nodes.** Each entity's schema + single-datum invariants + context (`location`, `origin`, `authority`, `governance`) + the **Avro message contracts** between services. Declare the `authority` (system-of-record) for every fact that exists in more than one place.
- **Data Flow = the transform graph.** Each step `(state, in) → (state', out)`, tagged `pure | effect`. Every `effect` carries an **idempotency key + compensation** in the flow. Every ingress edge lists the **LOCAL validation rules** applied before a datum is consumed. One path per PO Test Scenario.
- **Service Map = transform ownership + boundaries.** Each service is a unit; its edges are trust boundaries (untrusted-until-validated, non-transitive). The runtime trust profile is just the `origin`/`authority`/boundary tags made explicit. **Also name the Observability Surface** — the required dashboards/panels mapped to PO scenarios (see `df-observability`).

## Ownership handoff (PO → SA)
The PO + SMEs defined the semantics (data, `origin`, `trust`, `authority`, `governance`, the validation-rule predicates). Your job is **formalization**:
- turn each into a schema / Avro contract;
- assign every validation rule its enforcement **locus** (`LOCAL` → reject at an edge; `GLOBAL` → reconcile by `authority`) and **mechanism** (XSD / Schematron / DB constraint / reconciliation job — e.g. TR2 does XSD for structure + Schematron for cross-field business rules);
- tag transforms `pure`/`effect` with idempotency + compensation.
Do **not** re-decide domain facts (which source is authoritative, what must be true) — if one is missing or wrong, loop back to PO.

## Instructions
1. Decompose requirements into single-responsibility services. If a service needs "and" to describe it, split it.
2. Draft the **Data Model** (entities, ownership, PHI/PII class, retention, authority, Avro contracts).
3. Draw the **Data Flow** — one path per PO scenario: in → transform → store → out; pub/sub + async by default; every sync hop gets an ADR.
4. Fill the **Service Map** — per service deltas + the Observability Surface keyed to scenarios.
5. Tag every transform `pure`/`effect`; give effects idempotency + compensation. Cross-system invariants (PO `GLOBAL` rules) become reconciliation paths with a named `authority`.

## Exit gate
- **Cold Developer test** — can a fresh developer build every service from these three docs alone, no invented contracts?
- **Cold Infra test** — can a fresh infra architect deploy across DTAP, no guessed trust boundaries?
- **Coverage** — every PO scenario has a Data Flow path; every effect has idempotency + compensation; every cross-system fact has a declared authority.
