---
name: service-mapper
description: Analyze a codebase to produce a complete service map — microservices, inter-service communication, database ownership, external integrations, and event flows. Generates AI-agent-friendly markdown. Use when onboarding to a new codebase, auditing architecture, updating CLAUDE.md, or before planning new features. Triggers on "map services", "service map", "map the architecture", "what services exist", "how do services communicate", "map this repo", "generate service map", "architecture map".
---

# Service Mapper

Analyze a codebase and produce a structured, AI-agent-friendly service map. The output documents every microservice, how they communicate, what databases and tables they own, and what external systems they integrate with.

## When to Use

- Onboarding to an unfamiliar codebase
- Generating or updating a CLAUDE.md or SERVICE-MAP.md
- Before planning a new feature (understand what exists)
- Auditing service boundaries and ownership
- Detecting architectural violations (shared DBs, direct HTTP between services, etc.)
- After significant refactoring to verify the architecture still makes sense

## Workflow

Execute these steps in order. Each step builds on the previous.

### Step 1: Identify Service Boundaries

Scan the repository structure to find all deployable units (services, workers, lambdas, cron jobs).

**What to look for:**

| Signal | Examples |
|--------|----------|
| Entrypoints | `main.go`, `main.ts`, `index.ts`, `app.py`, `Program.cs`, `main.rs` |
| Build configs | `Dockerfile`, `docker-compose.yaml`, `serverless.yml`, `app.yaml` |
| Package manifests | `package.json`, `go.mod`, `Cargo.toml`, `pom.xml`, `*.csproj` |
| Deployment specs | K8s manifests, Terraform, Helm charts, DO app specs |
| Monorepo markers | `packages/`, `services/`, `apps/`, `cmd/`, `internal/` |

**For each service, record:**
- Name
- Language / framework
- Entrypoint file
- Port (if HTTP)
- Type: `webservice` | `worker` | `cron` | `lambda` | `gateway`

### Step 2: Map Inter-Service Communication

For each service, trace how it talks to other services.

**Communication patterns to detect:**

| Pattern | How to Find |
|---------|-------------|
| **REST / HTTP** | Look for HTTP client calls, `fetch`, `axios`, `http.Get`, base URLs pointing to other services |
| **Message bus (RabbitMQ, Kafka, NATS, SQS)** | Look for `publish`, `subscribe`, `consume`, queue names, exchange declarations, topic subscriptions |
| **gRPC** | Look for `.proto` files, gRPC client/server setup, `grpc.Dial` |
| **Shared library / SDK** | Look for internal packages imported across services (e.g., `DatabaseClient`, shared types) |
| **Direct function calls** | In monoliths or tightly coupled services — function imports across module boundaries |
| **Event contracts** | Shared schema definitions (Zod, Protobuf, Avro, JSON Schema) that define inter-service messages |

**For each connection, record:**
- Source service
- Target service
- Protocol (HTTP / AMQP / gRPC / SDK / etc.)
- Direction (unidirectional / request-response / pub-sub)
- What data flows (event names, endpoint paths, RPC methods)

### Step 3: Map Database Ownership

Identify every database, schema, or table and determine which service owns it.

**What to look for:**

| Signal | Examples |
|--------|----------|
| DB connection strings | `DATABASE_URL`, `SUPABASE_URL`, `MONGO_URI`, connection config |
| ORM models / migrations | Prisma schema, TypeORM entities, GORM models, Alembic migrations, Knex migrations |
| Raw SQL | `CREATE TABLE`, `SELECT FROM`, table names in queries |
| DB client imports | Which services import the DB client or ORM? |
| Gateway pattern | Does one service proxy DB access for others? |

**For each data store, record:**
- Type (PostgreSQL, MongoDB, Redis, S3, etc.)
- Tables / collections (list them)
- Owner service (the service that writes to it)
- Reader services (services that read from it — directly or via gateway)
- Access pattern: `direct` | `via-gateway-service` | `via-message-bus`

**Flag violations:**
- Multiple services writing to the same table (shared mutable state)
- Services bypassing a DB gateway to access the database directly
- No clear owner for a table

### Step 4: Map External Integrations

Find every connection to systems outside the codebase.

**What to look for:**

| Signal | Examples |
|--------|----------|
| API clients | REST clients, SDK imports, webhook handlers |
| API keys / secrets | Environment variables like `*_API_KEY`, `*_SECRET`, `*_TOKEN` |
| External URLs | Hardcoded or configured URLs to third-party services |
| Webhook endpoints | Routes that receive callbacks from external systems |

**For each integration, record:**
- External system name (e.g., Stripe, SendGrid, S3)
- Which service connects to it
- Direction: `outbound` (we call them) | `inbound` (they call us) | `bidirectional`
- Auth method (API key, OAuth, mTLS, etc.)
- Data exchanged (what we send/receive)

### Step 5: Trace Event Flows

For event-driven architectures, map the full lifecycle of key events.

**For each event type:**
- Publisher (which service emits it)
- Subscribers (which services consume it)
- Payload schema (or reference to contract)
- What triggers the event
- What downstream effects it causes

Build 3-5 critical flow diagrams showing end-to-end event chains (e.g., "user action → ingestion → processing → storage → notification").

### Step 6: Generate the Service Map

Produce the output document using the structure in [TEMPLATES.md](TEMPLATES.md).

---

## Discovery Commands

Use these to accelerate analysis. Adapt to the project's language/framework.

### Find entrypoints
```bash
# Go
find . -name "main.go" -not -path "*/vendor/*"

# Node/TypeScript
find . -name "index.ts" -path "*/src/*" -not -path "*/node_modules/*"

# Python
find . -name "main.py" -o -name "app.py" -o -name "wsgi.py" | grep -v __pycache__
```

### Find message bus usage
```bash
# RabbitMQ / AMQP
grep -rn "publish\|subscribe\|consume\|createChannel\|assertQueue\|assertExchange" --include="*.ts" --include="*.go" --include="*.py"

# Kafka
grep -rn "producer\|consumer\|KafkaClient\|kafka.NewReader\|kafka.NewWriter" --include="*.ts" --include="*.go" --include="*.py"

# Event type constants
grep -rn "EVENT_TYPE\|event_type\|EventType\|ROUTING_KEY\|routing_key" --include="*.ts" --include="*.go" --include="*.py"
```

### Find database access
```bash
# Table names in SQL
grep -rn "FROM \|INTO \|UPDATE \|CREATE TABLE\|ALTER TABLE" --include="*.ts" --include="*.go" --include="*.py" --include="*.sql"

# ORM models
grep -rn "Entity\|@Table\|@Model\|tableName\|__tablename__" --include="*.ts" --include="*.py" --include="*.java"

# DB connection setup
grep -rn "DATABASE_URL\|SUPABASE_URL\|MONGO_URI\|createConnection\|createPool\|getConnection" --include="*.ts" --include="*.go" --include="*.py" --include="*.env*"
```

### Find external API calls
```bash
# HTTP clients
grep -rn "axios\|fetch(\|http.Get\|http.Post\|requests.get\|requests.post\|HttpClient" --include="*.ts" --include="*.go" --include="*.py"

# API keys in env
grep -rn "API_KEY\|API_SECRET\|_TOKEN\|_SECRET" --include="*.env*" --include="*.yaml" --include="*.ts"
```

### Find deployment configs
```bash
# Docker
find . -name "Dockerfile" -o -name "docker-compose*.yaml" -o -name "docker-compose*.yml"

# Kubernetes
find . -name "*.yaml" -path "*/k8s/*" -o -name "*.yaml" -path "*/deploy*/*"

# Serverless
find . -name "serverless.yml" -o -name "serverless.ts"

# Cloud platform
find . -name "app.yaml" -o -name "app.spec.yaml" -o -name "*.tf"
```

## Quality Checks

Before presenting the service map, verify:

- [ ] Every service has a clear type (webservice/worker/cron/lambda/gateway)
- [ ] Every inter-service connection has protocol and direction documented
- [ ] Every database table has exactly one owner service identified
- [ ] Every external integration has the connecting service identified
- [ ] No orphan services (services with zero connections — likely missed something)
- [ ] Event flows cover the critical business paths
- [ ] ASCII diagrams are present for high-level architecture and key flows
- [ ] The map is self-contained — an AI agent can understand the architecture without reading code

## Supporting Files

- [TEMPLATES.md](TEMPLATES.md) — Output format and examples for the service map
