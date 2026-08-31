---
title: Person-Identifiable Data Segregation
type: reference
status: living
honours: Prime Directives 3, 4, 5, 8
---

# Reference: Person-Identifiable Data Segregation

## TL;DR

Make it **architecturally impossible** to reach person-identifiable data without explicit,
auditable authorization — by physically separating identity data from operational data into
distinct databases owned by distinct services. Policy controls can be misconfigured; a
missing join cannot.

> **The rule this pattern implements:** *person-identifiable data is physically separated
> from operational data, behind a single audited gateway.*
> Refer to it **by that name**. Some older kits cite it as "Prime Directive #14"; that
> ordinal has no referent — the canonical list in
> [`10-prime-directives.md`](10-prime-directives.md) has exactly ten entries and none of
> them is this rule. See [Naming](#naming) below.

---

## Intent

Physically separate identity data from operational data so that access to a person's
identity is a deliberate, logged act rather than a query away.

## Context and motivation

Any system that stores data about people — patients, claimants, employees, customers —
faces a common tension: operational services need to process records (incidents,
procedures, claims, transactions) while compliance frameworks (HIPAA, GDPR, PIPEDA,
SOC 2, CCPA) demand strict control over who can see the person behind the record.

Policy-based controls — row-level security, column encryption, role grants — are only as
strong as their configuration. A single misconfigured role, or an injection flaw in one
service, can expose everything.

This pattern removes that class of risk by making the **architecture** the enforcement
boundary:

- **Physical separation** — identity and operational data live in different databases, on
  different hosts, under different credentials. No query, no join, and no misconfiguration
  can bridge them from inside a single service.
- **Service-level access control** — only the identity gateway touches the identity
  database. An analytics service can be granted full read access to the operational
  database without exposing a single person's name.
- **Non-destructive erasure** — every identity record for a person can be physically
  deleted and the operational data remains intact, complete and queryable. The `person_id`
  foreign key still exists; it simply resolves to nothing.
- **Auditable chokepoint** — because the gateway is the only door, every access is logged
  in one place.

## When to apply

Apply this pattern when a service stores, processes or transmits any of the following about
an identifiable person:

- Full name (first, last, middle)
- Date of birth
- National identity or social-security number
- Email address
- Phone number
- Physical address
- Insurance or policy numbers
- Biometric identifiers
- Any field that, alone or combined, identifies a specific person

**If in doubt, apply it.** Separating early is cheap. Refactoring after identity data has
spread across databases is not.

---

## Architecture

```
                        ┌──────────────────────┐
                        │   External Clients   │
                        └──────────┬───────────┘
                                   │ HTTP
                        ┌──────────▼───────────┐
                        │     API Facade        │
                        │  (async request-reply │
                        │   over the bus)       │
                        └──────────┬───────────┘
                                   │ publishes request
                    ┌──────────────▼──────────────┐
                    │         Message Bus          │
                    │   {project}.person.*         │
                    │   {project}.operational.*    │
                    └──┬──────────────────────┬───┘
                       │                      │
              ┌────────▼────────┐   ┌─────────▼──────────┐
              │ Identity Gateway│   │Operational Gateway │
              │  (sole owner)   │   │   (sole owner)     │
              └────────┬────────┘   └─────────┬──────────┘
                       │                      │
              ┌────────▼────────┐   ┌─────────▼──────────┐
              │Identity Database│   │Operational Database│
              │ ─────────────── │   │ ────────────────── │
              │ person_id (PK)  │   │ record_id (PK)     │
              │ name            │   │ person_id (FK→void)│
              │ date_of_birth   │   │ event_date         │
              │ national_id_enc │   │ activity_code      │
              │ email           │   │ line_items         │
              │ policy_number   │   │ classification     │
              │ phone           │   │ location           │
              │ address         │   │ status             │
              └─────────────────┘   └────────────────────┘

   FK→void: person_id references a row that may or may not exist in the
   identity DB. The operational data is complete and valid either way.
```

### Structural rules

1. **Two physically separate databases.** No shared instance, no shared credentials, no
   shared host.
2. **The identity gateway is the ONLY service that reads or writes the identity DB.** No
   exceptions.
3. **The operational gateway is the ONLY service that reads or writes the operational DB.**
   No exceptions.
4. **`person_id` is the sole link between them.** It is assigned by the service, never by
   either database.
5. **The operational DB is fully functional without the identity DB.** Records still exist
   and queries still work — they just do not resolve to a person's name.
6. **No service makes a direct call to another service.** All inter-service communication
   goes over the bus (Prime Directives 3 and 4).

---

## Person ID strategy

`person_id` is the global identifier linking a person's identity to their operational
records across the platform. It **must** be assigned deliberately by the service, never
auto-generated by the database — no `SERIAL`, no `AUTO_INCREMENT`, no `IDENTITY`.

### Requirements

- **Globally unique** across all services, databases and tenants
- **Assigned by the identity gateway** at registration time
- **Deterministic** — the same person always gets the same id (a dedup strategy is needed)
- **Immutable** — once assigned, never changes

### Recommended strategies

Choose on your constraints. The pattern does not prescribe a format; it prescribes the
requirements above.

| Strategy | Pros | Cons | Best for |
|----------|------|------|----------|
| **UUIDv7** | Time-ordered (B-tree friendly), globally unique, no coordination | Opaque — no embedded meaning | Most implementations |
| **Prefixed UUIDv7** (e.g. `<platform>-<uuidv7>`) | Recognizable in logs, debuggable, globally unique | Slightly longer | Multi-platform environments |
| **Stride-based counter** | The assigning service can be inferred from the id delta | Collision risk if misconfigured; limits service count | Small, controlled environments |
| **Snowflake-style** (timestamp + service id + sequence) | Time-ordered, embeds origin service, high throughput | Needs a service registry for id assignment | High-volume systems |

### Stride-based counters, explained

Each service that may create person ids increments by a different fixed value (say 11, 123,
1007). Comparing consecutive ids tells you which service assigned them. Lightweight, but it
needs careful coordination to avoid stride collisions and it caps the number of assigning
services.

### Anti-patterns

- **Database auto-increment** — couples id generation to one DB instance.
- **Random UUIDv4** — not time-ordered; poor B-tree behaviour at scale.
- **Composite keys** (tenant + sequence) — leaks tenant identity into every foreign key.

---

## Async request-reply facade

When a caller needs a complete record — identity plus operational data — the system gives a
**synchronous-feeling experience over fully asynchronous internals**.

```
Caller        API Facade          Message Bus        Identity GW   Operational GW  Enrichment
 │                │                    │                  │               │             │
 │─ GET /rec/123 ►│                    │                  │               │             │
 │                │── publish ────────►│                  │               │             │
 │                │  {project}.data    │                  │               │             │
 │                │  .fetch.requested  │                  │               │             │
 │                │                    │── deliver ──────►│               │             │
 │                │                    │── deliver ───────────────────────►             │
 │                │                    │◄─ person data ──│               │             │
 │                │                    │◄─ operational ──────────────────│             │
 │                │                    │── deliver ────────────────────────────────────►│
 │                │                    │                  │               │ (joins data)│
 │                │                    │◄─ enriched ───────────────────────────────────│
 │                │◄─ consume ────────│                  │               │             │
 │                │  {project}.data    │                  │               │             │
 │                │  .fetch.completed  │                  │               │             │
 │◄─ 200 JSON ──│                    │                  │               │             │
```

### Components

**API facade**
- Accepts HTTP from external clients — the only edge service.
- Publishes a data-fetch request to the bus.
- Listens on a reply queue, correlated by `request_id`.
- Returns the enriched response.
- Has a configurable timeout (e.g. 5s); on expiry, return partial data or `408`.

**Enrichment service**
- Subscribes to both identity and operational response events.
- Correlates by `person_id` + `request_id`.
- Joins them into a composite record and publishes it.
- **This is the only place the two data sets meet — and it is audited.**

The caller gets the experience of a synchronous API call; the architecture stays async end
to end.

### Message events

| Event | Routing key | Publisher | Consumer |
|-------|-------------|-----------|----------|
| `DataFetchRequestedV1` | `{project}.data.fetch.requested` | API facade | Identity GW, Operational GW |
| `PersonDataResponseV1` | `{project}.person.data.response` | Identity GW | Enrichment |
| `OperationalDataResponseV1` | `{project}.operational.data.response` | Operational GW | Enrichment |
| `DataFetchCompletedV1` | `{project}.data.fetch.completed` | Enrichment | API facade |

---

## Right-to-erasure lifecycle

Supports GDPR right to erasure, HIPAA de-identification, CCPA right to delete and similar
regimes. Three phases: soft delete, hard delete, downstream purge.

```
Phase 1: SOFT DELETE          Phase 2: HARD DELETE           Phase 3: DOWNSTREAM PURGE
─────────────────────         ────────────────────           ─────────────────────────
Mark the row deleted          Physically remove the row      A tombstone event propagates
Grace period begins           once the retention period      Downstream caches and
(configurable: 30–90 days)    expires                        read-models purge any
Legal/compliance can          Irreversible                   enriched copies
review and cancel
```

### Events

| Phase | Event | Routing key | Purpose |
|-------|-------|-------------|---------|
| Request | `PersonErasureRequestedV1` | `{project}.person.erasure.requested` | Erasure requested — grace period starts |
| Soft delete | `PersonSoftDeletedV1` | `{project}.person.erasure.soft-deleted` | Marked deleted, not yet removed |
| Cancel | `PersonErasureCancelledV1` | `{project}.person.erasure.cancelled` | Cancelled during the grace period |
| Hard delete | `PersonHardDeletedV1` | `{project}.person.erasure.hard-deleted` | Physically removed — irreversible |
| Tombstone | `PersonTombstoneV1` | `{project}.person.erasure.tombstone` | Downstream services must purge cached identity data |

### After the hard delete

Operational data remains intact. The `person_id` foreign key still exists in operational
rows — it simply resolves to nothing. Clinical, incident, transaction and procedural data
are unaffected, and analytics queries keep working against anonymized records.

### The grace period

A configurable soft-delete window (typically 30–90 days) buys:

- legal or compliance review of the request,
- cancellation when the request was made in error,
- an audit trail of the request and the decision,
- time for downstream systems to prepare for the tombstone.

---

## Audit event schema

Every interaction with identity data is published to the bus as an audit event. The identity
gateway emits one for **every** operation — reads, writes, deletes, and lookups that return
"not found". No exceptions. This is Prime Directive 1 applied to a compliance boundary: an
access nobody recorded did not happen, as far as the auditor is concerned.

```go
// File: internal/contracts/pii_audit_events.go
// Version: V1 (append-only — never modify; add V2 instead)

package contracts

import "time"

// PIIAccessAuditV1 is published on every identity-database operation.
// Routing key: {project}.audit.pii.access
type PIIAccessAuditV1 struct {
    AuditID        string    `json:"audit_id"        avro:"audit_id"`
    Timestamp      time.Time `json:"timestamp"       avro:"timestamp"`
    PersonID       string    `json:"person_id"       avro:"person_id"`
    Action         string    `json:"action"          avro:"action"`
    Actor          string    `json:"actor"           avro:"actor"`
    Purpose        string    `json:"purpose"         avro:"purpose"`
    CorrelationID  string    `json:"correlation_id"  avro:"correlation_id"`
    FieldsAccessed []string  `json:"fields_accessed" avro:"fields_accessed"`
    Outcome        string    `json:"outcome"         avro:"outcome"`
    SourceIP       string    `json:"source_ip"       avro:"source_ip"`
}
```

| Field | Type | Description |
|-------|------|-------------|
| `audit_id` | string (UUID) | Unique id for this audit event |
| `timestamp` | time | When the access occurred (UTC) |
| `person_id` | string | Whose identity data was accessed |
| `action` | string | `READ` \| `WRITE` \| `DELETE` \| `SOFT_DELETE` \| `HARD_DELETE` |
| `actor` | string | Service name or user identity that initiated the access |
| `purpose` | string | Why — e.g. `enrichment`, `erasure_request`, `admin_lookup`, `registration` |
| `correlation_id` | string | Links to the originating request chain for tracing |
| `fields_accessed` | []string | Which fields were touched, e.g. `["name","dob","national_id"]` |
| `outcome` | string | `SUCCESS` \| `DENIED` \| `NOT_FOUND` |
| `source_ip` | string | Originating address, when the request chain carries one |

### Consumers

- **Audit store** — append-only and immutable.
- **Compliance reporting** — periodic reports on access patterns.
- **Alerting** — bulk reads, access from unexpected services, repeated `NOT_FOUND` lookups
  (a possible enumeration attack).

---

## Encryption guidance

Physical separation is the primary boundary. Encryption is defence in depth, not a
substitute — see [Anti-patterns of adoption](#anti-patterns-of-adoption).

**Recommended**

- **At rest** for the identity database (AES-256 or equivalent, usually a platform feature).
- **Field-level** for the highest-sensitivity columns (national id, policy numbers) —
  encrypted before storage, decrypted only by the identity gateway.
- **In transit** (TLS) between the gateway and its database.
- **Message-level** for identity data on the bus, where the bus is shared with services that
  must not see it.

**Not prescribed**

Cipher suites, key-management products, rotation schedules. Those follow the infrastructure
and the applicable regime. The pattern requires that encryption exists; it does not dictate
how.

---

## Tenancy guidance

### Recommended: one identity DB and one operational DB per tenant

Complete physical isolation between tenants. Where the platform's coordination layer —
message bus, service discovery, deployment tooling — is already a fixed cost, per-tenant
database isolation is operationally cheap. It also scales better: each tenant's data volume
is independent, and tenant databases can be placed geographically for latency or for
jurisdiction.

Most importantly it eliminates a whole class of cross-tenant leak by making it
**architecturally impossible** — the same move as the identity/operational split itself, and
the same reasoning as Prime Directive 8.

| Approach | Security | Operational cost | Risk |
|----------|----------|------------------|------|
| **Per-tenant DBs** (recommended) | Strongest — cross-tenant leaks architecturally impossible | Covered by the coordination layer already in place; scales per tenant | Lowest |
| Shared operational + per-tenant identity | Good — identity isolated; operational data is low-risk without the join | Medium | Medium |
| Fully shared (multi-tenant columns) | Policy-dependent — one query bug leaks across tenants | Cheapest up front | Highest |

---

## Anti-patterns of adoption

- **"We encrypt the sensitive column, so one database is fine."** Encryption is defence in
  depth, not a substitute for separation. The sensitive field belongs in the identity DB,
  with field-level encryption **and** physical separation.
- **"The gateway is the only service that *should* touch it."** Should is a policy claim.
  Separate credentials on a separate host is an architectural one.
- **A read-replica of the identity DB for analytics.** That is a second door.
- **Joining across the two databases in a reporting tool.** If the tool can join them, the
  separation has already failed.

---

## Compliance framework alignment

The pattern is framework-agnostic by design: the architectural decisions serve the security
principles the frameworks require, rather than any one framework's checklist.

| Pattern decision | Supports |
|------------------|----------|
| Physical database separation | HIPAA (minimum necessary), GDPR (data protection by design), SOC 2 (logical access controls) |
| Service-controlled person id | HIPAA (unique individual identifier), GDPR (pseudonymization) |
| Async enrichment; no direct identity access by operational services | HIPAA (access controls), GDPR (purpose limitation) |
| Right-to-erasure lifecycle | GDPR (right to erasure), CCPA (right to delete), PIPEDA (individual access) |
| Audit trail on every access | HIPAA (audit controls), SOC 2 (monitoring), GDPR (accountability) |
| Per-tenant database isolation | HIPAA (entity isolation), GDPR (data minimization), PIPEDA (safeguards) |
| Encryption at rest and field-level | HIPAA (encryption), GDPR (security of processing), SOC 2 (encryption) |

Alignment is not certification. It says the architecture does not stand in the way of an
audit; it does not say an audit has been passed.

---

## Domain-agnostic examples

The pattern works in any domain with person-identifiable data.

| Domain | Identity database | Operational database |
|--------|-------------------|----------------------|
| Healthcare / emergency response | Name, DOB, national id, insurance | Incidents, procedures, medications, diagnoses |
| Insurance | Claimant name, DOB, policy number, national id | Claims, adjustments, payments, coverage |
| HR / payroll | Employee name, DOB, national id, bank account | Timesheets, reviews, pay runs |
| Customer service | Customer name, email, phone, address | Tickets, orders, returns, interactions |
| Financial services | Account-holder name, national id, DOB | Transactions, balances, statements, alerts |

In every case: `person_id` links the two sides, the operational data is complete and useful
without the identity data, and the gateway is the only door.

---

## Naming

Refer to this as **the PII segregation rule**, or by the title of this document. Do **not**
cite it by ordinal.

Older kits carry the line *"Prime Directive #14 — PII physically separated"*. That ordinal
never resolved: the canonical list in [`10-prime-directives.md`](10-prime-directives.md) has
exactly ten entries and ends at ten, and the architecture axioms it might otherwise have
belonged to are numbered 1–37, where the entry at 14 is something unrelated. A reader arriving from one of
those kits should learn here that the number was never real, rather than try to restore it.

**An ordinal into a curated list fails open.** Once the list is re-curated the citation still
*reads* like a citation: nothing breaks loudly, no link check fires, and the reader trusts a
pointer to nothing. Name the rule instead — a name that stops resolving is a name a reader
can search for.

---

## See also

- [`10-prime-directives.md`](10-prime-directives.md) — the canonical ten. This pattern
  applies 3, 4, 5 and 8 to a compliance boundary; it is not an eleventh directive.
- [`8-implementation-patterns.md`](8-implementation-patterns.md) — the build defaults these
  services sit inside; *Message Bus Only Between Services* is the rule that keeps the
  gateway the only door.
- [`service-anatomy.md`](service-anatomy.md) — each gateway is one service, with one
  external integration and one database.
- [`observability-standard.md`](observability-standard.md) — where the audit stream is
  emitted and how it is surfaced.
- [`data-transform-model.md`](data-transform-model.md) — the enrichment step is a transform
  with two inputs; its edges are the boundary this pattern defends.
- Your organisation layer — the concrete broker, database platform, key-management service
  and audit sink this pattern binds to.
