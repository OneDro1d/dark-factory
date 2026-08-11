# Reference: 8 Implementation Patterns

Eight reusable building blocks for any service the Solution Architect designs. They are
**defaults**, not laws: use them unless an ADR says why not. Their value is that a reader
already knows the answer to eight questions before opening the code, which is what makes a
service reviewable by someone who did not write it.

Distilled from operating a message-driven estate of ~20 services in production. The code
sketches below are illustrative and deliberately language-neutral in intent — your
organisation layer names the actual libraries.

## Pattern 1: Specialized Services

**Statement:** each service does one thing.

One service per format, per destination, per concern. A new format means a new service, not a
new branch inside an existing one. The blast radius of a single-service failure stays bounded.

**Apply at SA:** decompose so each service has one responsibility. If a service description
needs the word "and" or "also", the boundary is probably wrong.

## Pattern 2: Async First, Fire-and-Forget

**Statement:** an entry point accepts the work, returns immediately with a correlation id, and
publishes onward. The caller does not wait.

```
receipt   := publishIngestion(ctx, payload)
response.header("X-Correlation-ID", correlationId)
response.status(202)                 // Accepted — not "done"
response.body(receipt)
```

**Apply at SA:** for each external-facing endpoint, decide whether the caller genuinely needs
a synchronous answer. If not, return 202 + correlation id and process asynchronously. Note
what 202 promises: *accepted*, not *succeeded* — the correlation id is how the caller finds
out which.

## Pattern 3: Message Bus Only Between Services

**Statement:** inter-service communication goes over the bus, schema-encoded, with schemas in
one shared place.

```
outQ.headers["X-Correlation-ID"] = classification.correlationId
tracing.inject(ctx, outQ.headers)
outQ.publish(encode(schema, payload))
```

**Apply at SA:** every inter-service call is a message unless an ADR justifies otherwise.
HTTP at the edge only. Record the sync-vs-async map explicitly, so the exceptions are
countable.

## Pattern 4: Config Over Code

**Statement:** topology lives in configuration. Queues, exchanges, routing keys, thresholds,
confidence cut-offs, rate limits — all declared, none compiled in.

```yaml
classifiers:
  classifier-a:
    subscribe_filter:
      event_types: ["logs"]
    confidence:
      base: 0.8
      boosts:
        - field: event_type
          value: "logs"
          amount: 0.1
```

**Apply at SA:** find every threshold, filter, route and limit in the design and declare its
config shape. Code reads config. A threshold that only exists in code is a threshold nobody
can change during an incident — which is Directive 10 failing quietly.

## Pattern 5: Observability Is a Prerequisite

**Statement:** metrics, structured logs, traces and a health endpoint are part of a service's
definition, not a follow-up ticket.

```
messagesProcessed = counter("messages_processed_total",
                            labels: service, status, format, error_type, response_code)
confidence        = histogram("confidence_score",
                            buckets: 0.5 0.6 0.7 0.75 0.8 0.85 0.9 0.95 0.98 1.0)
```

**Apply at SA:** the Observability Specification names metric names, label dimensions, log
fields, trace propagation, alert conditions and runbooks per service. See
[`service-anatomy.md`](service-anatomy.md) for the emission side and
[`observability-standard.md`](observability-standard.md) for the surface built on it.

## Pattern 6: Logic in Services, Not Databases

**Statement:** business logic lives in services. Databases store; they do not execute
business rules.

```
func isFormatX(payload) bool {
    streams   := payload.data["streams"]        // absent      -> false
    first     := streams[0]                     // not an array -> false
    return first.has("stream") && first.has("values")
}
```

**Apply at SA:** classification, validation, transformation and routing happen in services.
Stored procedures, triggers and business-logic views are anti-patterns — they are logic no
test suite runs and no code review sees. The Data Architecture records who owns each data
domain; a gateway service per domain is a good default for enforcing that boundary.

## Pattern 7: Fork and Reuse

**Statement:** every service shares one boot sequence — init, metrics server, broker connect,
queue bind. A new service is a clone with new names and new business logic. Infrastructure
comes free.

```
func init() {
    logStartService("IngestionAPI", version)
    startMetricsServer(metricsPort)
    conn      := brokerConnect()
    incomingQ  = conn.connectQueue("IncomingQueue")
    incomingQ.setEncoding(schemaCodec)
}
```

**Apply at SA:** do not redesign bootstrap per service. The Service Catalogue assumes this
pattern; per-service deviation needs an ADR. The payoff is not typing saved — it is that
every service fails in the same recognisable way.

## Pattern 8: At-Least-Once with Dead-Lettering

**Statement:** message → process → acknowledge. On failure, requeue once; on the second
failure, dead-letter. Something watches the dead-letter queue in real time.

**Apply at SA:** every consumer honours at-least-once plus dead-lettering, which means every
consumer must be **idempotent** — at-least-once without idempotence is duplicate processing
with extra steps. The Observability Specification names DLQ alerting; the Operational Knobs
include replay, drain and inspect.

## Anti-patterns

The SA should not produce architectures matching these:

| Anti-pattern | Fix |
|---|---|
| Synchronous service-to-service calls | Async messaging via pub/sub |
| Shared database between services | Each service owns its data; communicate via events |
| `latest` container tags | Semantic versioning (MAJOR.MINOR.PATCH) |
| Topology defined in code | Declare it in configuration |
| A logger whose error level exits the process | Know your logger; use the non-fatal level for non-fatal events |
| Hand-rolled broker plumbing per service | One shared library, no exceptions |
| 2 replicas | Minimum 3, except singleton ops tools |
| Ignoring dead-lettered messages | Monitor, investigate, replay or acknowledge |
| Edge protocol leaking past the edge | HTTP at the edge only; internal is messaging |

## See also

- [`service-anatomy.md`](service-anatomy.md) — what every service must include.
- [`10-prime-directives.md`](10-prime-directives.md) — the principles these patterns implement.
- [`data-transform-model.md`](data-transform-model.md) — the idioms here implement `pure` and
  `effect` transforms and reconciliation.
- Your organisation layer — the concrete libraries, schema registry and ops tooling.
