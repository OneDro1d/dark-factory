# Service Map Output Templates

The service map output must be structured for both human readability and AI agent consumption. Use consistent headers, tables, and ASCII diagrams so agents can parse sections programmatically.

---

## Full Output Structure

```markdown
# Service Map: [Project Name]

> Generated: [date]
> Repository: [repo URL or path]
> Services: [count]
> Languages: [list]

---

## Architecture Overview

[ASCII diagram showing all services and their primary connections]

```
[service-a] ──HTTP──> [gateway]
[service-b] ──AMQP──> [service-c]
[service-c] ──SQL───> [PostgreSQL]
[gateway]   ──AMQP──> [service-a]
                       [service-b]
```

---

## Services

### [service-name]

| Property | Value |
|----------|-------|
| **Type** | webservice / worker / cron / lambda / gateway |
| **Language** | Go / TypeScript / Python / etc. |
| **Framework** | Fastify / Echo / FastAPI / Spring / etc. |
| **Entrypoint** | `path/to/main.ts` |
| **Port** | 3000 (or N/A for workers) |
| **Health check** | `GET /health` (or N/A) |
| **Deployment** | Docker / K8s / DO App Platform / Lambda |

**Publishes:**
| Event / Endpoint | Target | Protocol |
|-----------------|--------|----------|
| `ORDER_CREATED` | message bus | AMQP |
| `POST /api/orders` | external clients | HTTP |

**Subscribes / Consumes:**
| Event / Endpoint | Source | Protocol |
|-----------------|--------|----------|
| `PAYMENT_COMPLETED` | message bus | AMQP |
| `DB_QUERY_RESPONSE` | database-service | AMQP |

**Database access:**
| Table | Access | Method |
|-------|--------|--------|
| `orders` | read/write (owner) | direct SQL |
| `users` | read | via database-service |

**External integrations:**
| System | Direction | Auth |
|--------|-----------|------|
| Stripe | outbound | API key |
| Webhook receiver | inbound | HMAC signature |

[Repeat for each service]

---

## Inter-Service Communication

### Communication Matrix

| From ↓ \ To → | service-a | service-b | service-c | gateway |
|----------------|-----------|-----------|-----------|---------|
| **service-a** | — | AMQP | — | HTTP |
| **service-b** | — | — | AMQP | — |
| **service-c** | AMQP | — | — | — |
| **gateway** | AMQP | AMQP | — | — |

### Event Catalog

| Event Type | Publisher | Subscribers | Payload Reference |
|------------|-----------|-------------|-------------------|
| `ORDER_CREATED` | order-service | notification-service, analytics | `OrderCreatedV1` |
| `PAYMENT_COMPLETED` | payment-service | order-service, accounting | `PaymentCompletedV1` |
| `USER_REGISTERED` | auth-service | notification-service, onboarding | `UserRegisteredV1` |

### Message Contracts Location

| Contract | File |
|----------|------|
| `OrderCreatedV1` | `packages/contracts/src/order.ts` |
| `PaymentCompletedV1` | `packages/contracts/src/payment.ts` |

---

## Database Ownership

### Data Store Inventory

| Store | Type | Owner Service | Access Pattern |
|-------|------|---------------|----------------|
| `main` PostgreSQL | RDBMS | database-service (gateway) | All services via message bus |
| `cache` Redis | Cache | gateway | Direct from gateway only |
| `files` S3 | Object store | media-service | Direct from media-service |

### Table Ownership

| Table | Owner (writes) | Readers | Notes |
|-------|---------------|---------|-------|
| `users` | auth-service | all (via gateway) | PII — restricted access |
| `orders` | order-service | analytics, reporting | High-write volume |
| `payments` | payment-service | order-service, accounting | Financial data |
| `audit_log` | all services | ops team | Append-only |
| `error_alerts` | all services | ops team, agents | Error aggregation |

### Violations

| Issue | Severity | Details |
|-------|----------|---------|
| Shared writer on `audit_log` | LOW | Acceptable — append-only by design |
| `analytics` reads `orders` directly | HIGH | Should go through gateway or message bus |

---

## External Integrations

| External System | Connecting Service | Direction | Protocol | Auth | Data |
|----------------|-------------------|-----------|----------|------|------|
| Stripe | payment-service | outbound | REST | API key | Charges, refunds |
| SendGrid | notification-service | outbound | REST | API key | Emails |
| Market-data API | data-ingestion | inbound (webhook) | HTTP | HMAC | Market indicators |
| Exchange API | trade-execution | bidirectional | REST + WebSocket | HMAC signing | Orders, fills, balances |
| Managed Postgres | database-service | outbound | REST | Service key | All DB operations |

---

## Critical Flows

### Flow 1: [Name — e.g., "Order Placement"]

```
User → [gateway] POST /orders
         │
         ▼
      [order-service] validates, creates order
         │
         ├── publishes ORDER_CREATED ──→ [notification-service] sends confirmation email
         │
         └── publishes ORDER_CREATED ──→ [payment-service] initiates charge
                                            │
                                            └── publishes PAYMENT_COMPLETED
                                                   │
                                                   ▼
                                            [order-service] updates order status
                                                   │
                                                   └── publishes ORDER_FULFILLED
```

**Tables touched:** `orders` (write), `payments` (write), `email_logs` (write)
**External calls:** Stripe (charge), SendGrid (email)
**Failure points:** Stripe timeout, duplicate payment events

### Flow 2: [Name]

[Same format — repeat for 3-5 critical flows]

---

## Configuration & Environment

### Shared Environment Variables

| Variable | Used By | Purpose |
|----------|---------|---------|
| `MESSAGE_BUS_URL` | all services | Message bus connection |
| `DATABASE_URL` | database-service | PostgreSQL connection |
| `NODE_ENV` | all services | Environment identifier |
| `PORT` | webservices | HTTP listen port |

### Runtime Configuration

| Config Key | Source | Used By |
|------------|--------|---------|
| `min_nav_threshold` | `operational_config` table | intent-calculation |
| `risk_free_rate` | `operational_config` table | analytics |

---

## Architecture Notes

### Patterns in Use
- [ ] Database Gateway (single service owns DB access)
- [ ] Event-Driven (services communicate via message bus)
- [ ] API Gateway (single entry point for external clients)
- [ ] Saga / Choreography (multi-step workflows via events)
- [ ] CQRS (separate read/write models)
- [ ] Sidecar (helper process alongside main service)

### Known Technical Debt
| Issue | Impact | Suggested Fix |
|-------|--------|---------------|
| [description] | [what it affects] | [how to address] |

### Architectural Decisions
| Decision | Rationale | Date |
|----------|-----------|------|
| [e.g., "All DB via gateway"] | [why] | [when decided] |
```

---

## Tips for AI-Friendly Output

1. **Use tables over prose.** Tables are parseable; paragraphs require inference.
2. **Use consistent headers.** Always `## Services`, `## Inter-Service Communication`, etc. Agents can `grep` for sections.
3. **Include the communication matrix.** A single table showing who talks to whom is the fastest way for an agent to understand the topology.
4. **Name events consistently.** Use the exact constant names from code (e.g., `EVENT_TYPES.ORDER_CREATED`), not paraphrases.
5. **Mark violations explicitly.** Don't bury problems in prose. Use a dedicated table with severity.
6. **Include file paths.** Every service, contract, and config reference should include the file path so agents can navigate directly.
7. **ASCII diagrams for flows.** Use `→`, `│`, `├──`, `└──` for flow diagrams. These render in any terminal or markdown viewer.
8. **Keep it flat.** Avoid deeply nested sections. Two levels of headers maximum (`##` and `###`).
