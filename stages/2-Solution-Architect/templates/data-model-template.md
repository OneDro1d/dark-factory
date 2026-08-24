---
title: Data Model — <Product Name>
stage: 2. Solution Architect
type: data-model
status: template
consumes: PO requirements + test scenarios
---

# Data Model — <Product Name>

## TL;DR

<One paragraph: the core entities, who owns what, and the data-classification headline (e.g. "all patient data is PHI").>

## Entities

| Entity | Purpose | Owner service | Cardinality | Data class | Retention | `origin` | `authority` (SoR) |
|---|---|---|---|---|---|---|---|
| `<Entity>` | <one line> | `<service>` | <1:N> | PHI/PII/public | <period> | <form/scan/API/service> | <who is source-of-truth> |

One owner per domain (Pattern 6 — logic in services, no shared DB across services). `origin` records where each entity enters the system (audit, never trust); `authority` names the system-of-record for facts that exist in more than one place (drives reconciliation). See [`reference/data-transform-model.md`](../../../reference/data-transform-model.md).

## Invariants (validation rules)

Facts that must hold across the design (the Adversary tests each). Each is a **validation rule** — tag it `LOCAL` (checkable at one edge → reject) or `GLOBAL` (spans services/time → reconcile, naming the `authority` that wins on conflict):

- <e.g. "An event is published exactly once per source; consumers dedupe on `(id, seq)`.">
- <e.g. "No service reads another service's database.">

## Message contracts (Avro)

What flows between services. The Developer lane implements these exactly; no private side channels (Directive 2).

| Producer | Consumer | Exchange / routing key | Avro schema | Key fields |
|---|---|---|---|---|
| `<svc-a>` | `<svc-b>` | `<exchange>` / `<key>` | `internal/models/<x>.avsc` | <fields> |

## Persistence

| Store | Owner | Engine | PHI/PII | Encryption |
|---|---|---|---|---|
| `<db>` | `<service>` | Postgres / … | yes/no | at-rest + in-transit |

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Idempotency & dedup keys

Per message type, the key that makes reprocessing safe (at-least-once + DLQ, Pattern 8).

## PHI/PII handling

Per entity: at-rest encryption, in-transit, audit sink (an immutable ledger for safety-grade), segregation boundary, retention + deletion path.

## Open items

<Unresolved data questions; each flagged as a follow-up.>
