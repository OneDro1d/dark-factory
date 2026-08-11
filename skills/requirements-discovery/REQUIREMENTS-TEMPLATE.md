# Feature: [NAME]

> **Status:** DRAFT | APPROVED | IN_PROGRESS | COMPLETE
> **Author:** [name]
> **Date:** [YYYY-MM-DD]
> **Repository:** [the service repo this change lands in]
> **Type:** new-service | new-handler | new-endpoint | cross-cutting | new-table

---

## 1. Context

### Problem Statement
[1-2 sentences: What problem does this solve? Why now?]

### Business Value
[What changes for users or the platform when this ships?]

### Reference Implementation
[Which existing service/handler should this be modeled after?]
- **Service template:** `packages/accounting` | `packages/data-ingestion` | etc.
- **Handler template:** `packages/trade-execution/src/handlers/executeIntent.ts` | etc.
- **Deviations from template:** [List any differences and why]

---

## 2. Data Model

### New Tables

```sql
-- Owner service: [service-name]
-- Read by: [service-a, service-b]
CREATE TABLE table_name (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- columns here, always TEXT not VARCHAR
);

-- Indexes
CREATE INDEX idx_table_column ON table_name (column);

-- RLS (if applicable)
ALTER TABLE table_name ENABLE ROW LEVEL SECURITY;
```

### Table Modifications

```sql
-- Describe what changes and why
ALTER TABLE existing_table ADD COLUMN new_column TEXT;
```

### Data Ownership

| Table | Owner (writes) | Readers |
|-------|---------------|---------|
| table_name | service-name | service-a, service-b |

### DatabaseClient Methods Required

```typescript
// New methods needed in packages/shared/src/db-client/index.ts
// Handler: packages/database-service/src/handlers/query.ts or command.ts

// Query (read)
async getThingById(id: string): Promise<Thing | null>
async listThingsByStrategy(strategyId: string): Promise<Thing[]>

// Command (write)
async createThing(thing: CreateThingInput): Promise<Thing>
async updateThingStatus(id: string, status: string): Promise<void>
```

---

## 3. Message Contracts

### New Events

```typescript
// Append to @<org>/message-bus-contracts

// Event: THING_REQUESTED
export const ThingRequestedPayloadV1 = z.object({
  request_id: z.string().uuid(),
  strategy_id: z.string().min(1),
  requested_at: z.string().datetime(),
});
export type ThingRequestedPayload = z.infer<typeof ThingRequestedPayloadV1>;

// Event: THING_COMPLETED
export const ThingCompletedPayloadV1 = z.object({
  request_id: z.string().uuid(),
  strategy_id: z.string().min(1),
  result: z.object({ /* fields */ }),
  completed_at: z.string().datetime(),
});
export type ThingCompletedPayload = z.infer<typeof ThingCompletedPayloadV1>;
```

### New Queues

| Queue Name | Event Type | Consumer Service |
|------------|-----------|-----------------|
| `service-name.thing-requested` | THING_REQUESTED | service-name |
| `other-service.thing-completed` | THING_COMPLETED | other-service |

### Event Flow Diagram

```
[trigger] → EVENT_A → [this-service] → EVENT_B → [downstream-service]
                            │
                            ▼
                       [database-service]
                            │
                            ▼
                        PostgreSQL
```

### Existing Events Consumed

| Event | Published By | What This Service Does With It |
|-------|-------------|-------------------------------|
| TRADE_EXECUTED | trade-execution | [describe reaction] |

### Existing Events Published

| Event | Consumed By | When Published |
|-------|------------|----------------|
| THING_COMPLETED | other-service | After processing completes |

---

## 4. Handlers

### Handler: handleThingRequested

- **Trigger:** `THING_REQUESTED` event (RabbitMQ subscription)
- **Input:** `ThingRequestedPayloadV1`
- **Dependencies:** DatabaseClient, [other services via message bus]
- **Logic:**
  1. Validate request_id not already processed (idempotency)
  2. Fetch required data via `db.getX()`
  3. Perform business calculation
  4. Write result via `db.createY()`
  5. Publish `THING_COMPLETED` event
- **Output:** Publishes `THING_COMPLETED`
- **Error handling:** Log warning and skip if already processed. Throw on DB errors (message will be requeued).
- **Idempotency:** Check `request_id` against processed records

### Scheduler: thingScheduler (if applicable)

- **Trigger:** Cron expression or interval (e.g., `0 * * * *` = hourly)
- **Disable flag:** `DISABLE_THING_SCHEDULER=true`
- **Logic:**
  1. Fetch pending items from DB
  2. Process each item
  3. Publish events for completed items
- **Concurrency:** Sequential (one at a time) | Parallel (batch)

---

## 5. HTTP Endpoints (if applicable)

### `GET /health`
Standard health check (all services get this automatically).

### `POST /api/thing`
- **Auth:** API key | Clerk token | None (internal)
- **Request body:**
  ```json
  { "strategy_id": "uuid", "amount": 100 }
  ```
- **Response:**
  ```json
  { "success": true, "data": { "id": "uuid" } }
  ```
- **Validation:** Zod schema in route handler
- **Error response:** Standard error format from CLAUDE.md

---

## 6. Integration Test Scenarios

> Tests are verified against REAL infrastructure (dev DB, dev RabbitMQ).
> Each scenario follows TRIGGER → VERIFY → EXPECT.

### Scenario 1: [Primary happy path]

**TRIGGER:**
```
Emit THING_REQUESTED event to dev RabbitMQ:
{
  "request_id": "test-uuid-1",
  "strategy_id": "test-main-1",
  "requested_at": "2026-01-15T12:00:00Z"
}
```

**VERIFY:**
```sql
-- Check target table for new record
SELECT * FROM table_name WHERE request_id = 'test-uuid-1';

-- Check no errors fired
SELECT * FROM email_logs WHERE created_at > '[test-start-time]' AND subject LIKE '%error%';
```

**EXPECT:**
- Row exists in `table_name` with `status = 'COMPLETED'`
- Service logs show: `"Received THING_REQUESTED"` → `"Processing complete"`
- No error-level logs
- No entries in email_logs

### Scenario 2: [Idempotency — duplicate event]

**TRIGGER:**
```
Emit the SAME THING_REQUESTED event again (same request_id "test-uuid-1")
```

**VERIFY:**
```sql
-- Count records with this request_id
SELECT count(*) FROM table_name WHERE request_id = 'test-uuid-1';
```

**EXPECT:**
- Still exactly 1 row (not 2)
- Service logs show: `"Already processed, skipping"`
- No error-level logs

### Scenario 3: [End-to-end pipeline]

**TRIGGER:**
```sql
-- Insert test data that triggers the full pipeline
INSERT INTO trigger_table (id, strategy_id, data) VALUES ('test-e2e', 'test-main-1', '...');
```

**VERIFY:**
```sql
-- Check each step of the pipeline produced output
SELECT * FROM step1_table WHERE trigger_id = 'test-e2e';
SELECT * FROM step2_table WHERE trigger_id = 'test-e2e';
SELECT * FROM final_table WHERE trigger_id = 'test-e2e';
```

**EXPECT:**
- Records exist at each pipeline step
- Final record has correct calculated values
- Total pipeline time < 10 seconds

---

## 7. Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `RABBITMQ_URL` | Yes | - | RabbitMQ connection string |
| `NODE_ENV` | Yes | development | Environment flag |
| `PORT` | No | [number] | HTTP server port |
| `DISABLE_THING_SCHEDULER` | No | false | Disable background scheduler |

### Runtime Config (operational_config)

| config_key | Type | Default | Description |
|------------|------|---------|-------------|
| `thing_threshold` | number | 100 | Threshold for thing processing |

---

## 8. Deployment

### Service Configuration

| Field | Value |
|-------|-------|
| **Port** | [number] |
| **Health check** | `/health` |
| **Replicas** | 1 |
| **Resources** | 512MB RAM, 0.5 CPU |
| **Dependencies** | RabbitMQ, database-service |

### DigitalOcean App Spec (additions)

```yaml
- name: service-name
  github:
    repo: <org>/<service-repo>
    branch: main
    deploy_on_push: true
  source_dir: /
  dockerfile_path: packages/service-name/Dockerfile
  instance_count: 1
  instance_size_slug: professional-xs
  http_port: [port]
  health_check:
    http_path: /health
  envs:
    - key: RABBITMQ_URL
      value: ${RABBITMQ_URL}
    - key: NODE_ENV
      value: production
```

### Dockerfile

```dockerfile
# Standard pattern - copy from existing service Dockerfile
FROM node:22-slim
# ... (follows existing service pattern)
```

---

## 9. Definition of Done

- [ ] All acceptance criteria pass as automated tests (`pnpm test`)
- [ ] Message contracts published to `@<org>/message-bus-contracts` (version bumped)
- [ ] Database migrations applied to dev Supabase instance
- [ ] DatabaseClient methods added and working
- [ ] Service builds successfully (`pnpm build`)
- [ ] Health check responds on configured port
- [ ] NotifyingLogger + global error handlers implemented
- [ ] Graceful shutdown handles SIGTERM/SIGINT
- [ ] Integration test passes against running RabbitMQ
- [ ] Deployed to DigitalOcean and health check passes
- [ ] [Custom criteria specific to this feature]

---

## 10. Out of Scope

[Explicitly list what this feature does NOT include to prevent scope creep]

- Does NOT handle [X]
- Does NOT modify [Y]
- [Z] will be addressed in a separate requirements doc
