# Reference: Message-Driven Service Patterns

Three patterns that answer questions
[`8-implementation-patterns.md`](8-implementation-patterns.md) raises and does not answer.
Pattern 2 there tells the Solution Architect to decide whether a caller *genuinely needs a
synchronous answer* — and says nothing about what to do when the answer is yes. Pattern 3
puts schemas "in one shared place" — and says nothing about how that place is allowed to
change. Pattern 7 assumes every service can be cloned and scaled — which is only true if
nothing important is sitting in one instance's memory.

Like the eight, these are **defaults, not laws**: use them unless an ADR says why not.

**Provenance.** Distilled from operating message-driven estates in production, and promoted
here from an organisation layer where each was written against one platform's broker, schema
library and language. The principle is what survived the move; the libraries did not, and
your organisation layer names them.

---

## Pattern A: Append-Only Contracts

**Statement:** the shared schema definition is append-only. New event types and new payload
versions are added. Existing ones are never modified and never removed.

**The reason is deployment, not taste.** A consumer you did not deploy, cannot see, and did
not know about is running against the shape you published last quarter. Changing that shape
does not migrate it — it breaks it, at a time and in a service neither of you chose.

**The rules:**

| Change | Allowed | Version bump |
|---|---|---|
| Add a new event type | yes | minor |
| Add an **optional** field to an existing payload | yes | patch |
| Add a new numbered version of a payload | yes | minor |
| Add a value to an enum a consumer must handle | **no** — publish `V2` | minor |
| Rename or remove an event type | **no** | — |
| Change a field's type, or make an optional field required | **no** | — |

**Versions live side by side.** `V1` is frozen, not deleted. Consumers accept the union of
the versions they understand and ignore the rest; a producer states which version it emits.
This is the same discipline as an additive database migration, applied to the wire.

**Retirement is possible, and it is an evidence problem, not a policy exception.** An event
type may be removed only once you can show nobody consumes it — which means per-event-type
consumption telemetry has to exist *before* you need it. Without that evidence there is no
honest way to distinguish "unused" from "used by someone quiet", so the answer stays no.

**Apply at SA:** name the shared schema artefact and its versioning rule in the design.
Record which services produce and which consume each event type — that table is what later
makes retirement decidable. An estate that cannot answer "who consumes this" has chosen to
keep every contract forever.

---

## Pattern B: Request/Response Over the Bus

**Statement:** when a caller genuinely needs an answer, correlate a request and a response
over the same bus. Do not open a second, synchronous channel between services to get it.

```
Caller                                            Owning service
  │                                                     │
  │ 1. mint correlationId                               │
  │ 2. subscribe to the response, THEN publish  ───────► │ 3. handle
  │                                                     │
  │ 5. match on correlationId  ◄─────────────────────── │ 4. reply, echoing
  │    (or time out)                                     │    correlationId
```

**Step 2 is ordered, and the order is the pattern.** Subscribe first, then publish. A fast
responder can answer before a subscription established afterwards exists, and the reply is
then delivered to nobody. This failure is load-dependent, so it appears in production and
not in the test that ran on a slow laptop.

**A timeout means *unknown*, not *failed*.** The request may have been processed and the
reply lost. The caller must either retry idempotently or surface the ambiguity — it must not
report failure it has not observed.

**Trade-offs:**

| Pro | Con |
|---|---|
| One channel to secure, observe and reason about | Latency floor is two bus hops, not one call |
| The owning service keeps its data boundary | Caller now holds in-flight state for the timeout window |
| Backpressure and DLQ handling come for free | Sync-shaped coupling reappears, just less visibly |

**Operability requirements:**
- A metric for requests timed out, labelled by request type.
- A gauge of in-flight correlations per caller; unbounded growth is the leak.
- A counter of responses arriving with no matching correlation — these are the step-2 race
  and the late replies, and they should be near zero.

**Apply at SA:** count these. Every one is sync coupling wearing async clothes, and the
count belongs next to the sync-vs-async map Pattern 3 asks for. A count that grows release
over release is design debt with a number attached.

---

## Pattern C: Stateless Service

**Statement:** a service instance holds nothing in memory that another instance would need
to do the same work.

**Where state is allowed to live:**

| Location | Holds |
|---|---|
| The bus | work in flight — unacknowledged messages, queue depth |
| The owning service's store | anything durable |
| The external system of record | balances, positions, whatever it is authoritative for |

**In memory, allowed:** credentials and configuration read at startup; a connection or
channel to the broker; a cache with an explicit TTL whose loss costs latency and nothing
else.

**In memory, not allowed:** session or workflow state (lost on restart); partial processing
state (unrecoverable after a crash); counters and running aggregates (they will not sum
across instances, and the number you read will be one instance's opinion).

**Two tests, and both are cheap:**
1. Kill any one instance mid-work. Nothing acknowledged is lost, and the work is either
   redelivered or was already durable.
2. Add an instance. No coordination step, no leader election, no rebalance ritual.

If either test needs an explanation, the service is stateful and should say so in an ADR —
along with how it recovers.

**This is what makes Pattern 7 true.** "A new service is a clone with new names" only holds
while instances are interchangeable. It is also the precondition for at-least-once delivery
(Pattern 8) to be survivable: redelivery to a *different* instance is only safe if that
instance knows as much as the one that died.

**Apply at SA:** for each service, state where its state lives. Any in-memory entry that is
not a startup constant or a TTL'd cache needs its recovery story in the design, not in the
incident.

---

## See also

- [`8-implementation-patterns.md`](8-implementation-patterns.md) — the eight these three
  complete.
- [`service-anatomy.md`](service-anatomy.md) — health, config-at-startup and graceful
  shutdown, which Pattern C depends on.
- [`10-prime-directives.md`](10-prime-directives.md) — Directive 4 (async by default) is the
  rule Pattern B is the sanctioned exception to.
- [`observability-standard.md`](observability-standard.md) — where the counters Patterns A
  and B require are surfaced.
