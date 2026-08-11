---
title: Per-Service Build Spec (CLAUDE.md) — <service-name>
stage: 3. Developer
type: per-service-build-spec
status: template
consumes: SA service map entry, data model, message contracts, data flow
---

# <service-name> — Build Spec

> This is the primer that boots a cold AI developer for this service and travels with the code as its CLAUDE.md. Keep it true — it is validated by booting a fresh session against it.

## TL;DR

<One paragraph: what this service does (single responsibility), what it consumes, what it produces.>

## Anatomy deltas (vs platform default)

Defaults from [`reference/service-anatomy.md`](../../../reference/service-anatomy.md). Record only what differs.

| Component | Default | This service |
|---|---|---|
| Health | `:8080/healthz` | <default / override + ADR> |
| Metrics | `:9090/metrics` | <default + service-specific labels> |
| Language | Go + TwistyGo | Go / .NET+sidecar / … |
| DLQ | single-requeue → DLQ | <bindings> |

## Message contracts

| Direction | Exchange / routing key | Avro schema | Notes |
|---|---|---|---|
| consume | `<exchange>` / `<key>` | `internal/models/<x>.avsc` | |
| publish | `<exchange>` / `<key>` | `internal/models/<y>.avsc` | |

Schemas must match the SA Data Model exactly. No private side channels (Directive 2).

## Data this service owns

<What it persists (if anything), where, PHI/PII class. Logic lives here, not in the DB (Pattern 6).>

## Quick commands

```bash
make build          # multi-arch
make test           # unit + integration
make run-local      # bring up against local RabbitMQ
<smoke test cmd>    # the reproducible smoke test the adversary will run
```

## Test expectations

| Level | What | Source |
|---|---|---|
| unit | <business logic> | this spec |
| integration | <consume→transform→publish> | SA message flow |
| E2E touchpoint | <which PO scenario> | PO test scenarios |

## Build status

- [ ] Skeleton forked (Pattern 7)
- [ ] Contracts implemented
- [ ] Anatomy complete
- [ ] Tests green
- [ ] Adversary Developer: Pass

<!-- ───────────── AI-AGENT CONTEXT BELOW ───────────── -->

## Build sequence

1. Fork `cmd/<skeleton>`, rename, wire queues from `settings.yaml`.
2. Implement consume → transform → publish per the Data Flow.
3. Add metrics labels, structured logs (`Log.Warn` only), DLQ bindings.
4. Write unit + integration tests; add the smoke test.
5. Update this spec's Build status; submit to Adversary Developer.

## Loop-back

If a needed message contract or data field is missing from the SA Data Model, do not invent it — file an SA loop-back. Inventing contracts is the most expensive silent error in the factory.
