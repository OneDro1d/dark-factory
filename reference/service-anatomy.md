# Reference: Service Anatomy

Every service the Solution Architect designs includes the components below. This is the
**generic** anatomy: what must exist and why. The concrete binding — which logger, which
message library, which health path — belongs in your organisation layer, and the SA records
only the **deltas** from that binding in the Service Map.

Service Anatomy is non-negotiable. A service that cannot meet it needs an ADR naming the
deviation and the alternative posture. "We didn't get to it" is not a deviation, it is an
unfinished service.

| Component | What it does | Typical default |
|---|---|---|
| **Health endpoint** | orchestrator readiness/liveness probes | `:8080/healthz` |
| **Metrics endpoint** | scrape target for the metrics backend | `:9090/metrics` |
| **Structured logging** | machine-queryable events, one line per event | JSON to stdout |
| **Dead-letter handling** | failed messages are recoverable, not lost | per-service DLQ binding |
| **Correlation tracing** | one id joins every hop of one request | message + HTTP headers + log fields |
| **Graceful shutdown** | in-flight work finishes before the process exits | signal handler drains, then closes |
| **Config topology** | topology is declared, not compiled in | a config file, per-environment overlays |

Why these seven and not others: each one is a precondition for a **later stage** to do its
job. Health and metrics are what Infrastructure wires; correlation and structured logs are
what QA reads to capture per-scenario evidence; DLQ and graceful shutdown are what Operations
depends on at 3am. A missing component does not degrade this service — it blinds a downstream
agent.

## Health endpoint

- 200 when the service is alive **and ready** — dependencies reachable, consumer attached.
- 503 when not ready. Readiness pulls the instance out of rotation; liveness restarts it
  after prolonged failure.
- Readiness that only proves the process is running is worse than none: it keeps a broken
  instance in the load balancer.

## Metrics endpoint

- Counter / Gauge / Histogram, labelled per service.
- A standard label set applied everywhere (`service`, `status`, `error_type`,
  `response_code`) plus service-specific labels, so cross-service queries are possible at all.
- Histogram buckets chosen for the dimension being measured. Latency and a 0–1 confidence
  score do not share a bucket layout.
- Every metric is named in the Observability Specification with type, labels and units. A
  metric nobody documented is a metric nobody will query.

## Structured logging

- One JSON line per event. Standard fields: `timestamp`, `level`, `service`, `version`,
  `correlationId`, `message`, plus service context.
- No multi-line stack traces in normal operation — they break line-oriented log search
  exactly when you need it.
- **Know what your logger's error level does.** Some libraries panic or exit the process on
  `Error`. If yours does, the non-fatal level is `Warn` and this is a platform-binding note
  worth writing down once, loudly, in your organisation layer.

## Dead-letter handling

- Two paths, deliberately distinguished:
  - **retry-then-dead-letter** for transient failure — requeue once, dead-letter on the
    second failure.
  - **dead-letter immediately** for unrecoverable failure — decode failures, schema
    mismatches, authentication failures. Retrying these just burns the queue.
- **One shared DLQ across services is an anti-pattern.** Per-service or per-data-path, or
  nobody can tell whose message failed.
- Durable named queues should be replicated/quorum where the broker supports it.
- DLQ depth is an alert, named in the Observability Specification. A DLQ nobody watches is a
  silent data-loss channel.

## Correlation tracing

- `correlationId` is set once at the **entry point** — HTTP request, scheduled trigger,
  manual invocation — and never regenerated downstream.
- Propagated through every message header and HTTP hop.
- Logged at every service boundary.
- This is what makes a `$correlationId` query reconstruct a whole request path across
  services. It is the single highest-value field in the log line, because it is what turns
  QA's "did scenario 4 work?" into an answerable question.

## Graceful shutdown

- Signal handler installed in `main()`.
- Stop accepting new work — shut down the HTTP server, cancel the consumer.
- Drain in-flight work: wait for outstanding messages to be acknowledged.
- Close connections cleanly — broker, database pool.
- Exit 0 on a clean drain, non-zero on timeout, so the difference is visible to the
  orchestrator instead of being averaged away.

## Config topology

- Topology — queues, exchanges, routing keys, thresholds, retries, batch sizes — lives in a
  config file, not in code.
- Config is read at startup. Reload means restart unless hot reload was explicitly designed.
- Per-environment overrides come from an overlay, not from a fork of the file.
- The SA names the config **schema**; the Developer generates the config against it. That
  ordering is what stops config from becoming a second, undocumented API.

## Service Anatomy entry per service

In the Service Catalogue, every service carries an Anatomy entry. Record **deltas** from the
platform default, not a restatement of it:

```text
Service: <name>
Health endpoint: <default, or override + ADR>
Metrics endpoint: <default, or override + ADR>
Logging: <platform default, or override + ADR>
Dead-letter:
  Strategy: retry-once → dead-letter (default) | immediate | <override + ADR>
  Bindings: <exchange + routing keys>
  Replay: <the command or tool that replays it>
Correlation:
  Source: <where correlationId is generated>
  Propagation: <which headers carry it>
Graceful shutdown:
  Drain timeout: <e.g. 30s>
  Pre-shutdown action: <e.g. stop consumer, finish in-flight, ack, close>
Config topology:
  Schema: <config schema name>
  Per-environment overrides: <yes/no, ADR if yes>
```

## See also

- [`8-implementation-patterns.md`](8-implementation-patterns.md) — the build defaults these
  components sit inside.
- [`observability-standard.md`](observability-standard.md) — emission is here, the **surface**
  built on top of it is there.
- [`data-transform-model.md`](data-transform-model.md) — a service is a unit: its edges are
  boundaries, its handlers are transforms.
- Your organisation layer — the concrete logger, broker library, health path and replay tool
  this anatomy binds to.
