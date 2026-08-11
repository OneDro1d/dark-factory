---
name: cold-start-generator
description: Analyzes any microservice codebase and generates a complete cold-start package — CLAUDE.md, custom skills, requirements template, development process docs, and onboarding guide. Works for any architecture. Use when setting up AI-assisted development for a new project. Triggers on "cold start", "set up AI development", "generate onboarding", "bootstrap project", "make this repo AI-ready".
---

# Cold Start Generator

Analyzes a codebase and generates everything needed for AI-assisted autonomous development: documentation, skills, templates, and onboarding materials.

## When to Use

- Setting up a new project for AI-assisted development
- Onboarding a new developer to an existing codebase
- Making any microservice codebase "AI-development ready"
- When someone says "make this repo work with Claude Code"

## Primary Goal

Produce a self-contained cold-start package that allows any developer to clone a repo, point Claude Code at the cold-start doc, and immediately be productive — including autonomous feature development.

## What Gets Generated

```
Output Package:
├── CLAUDE.md                          # Repo-level AI context (architecture, commands, conventions)
├── docs/
│   ├── COLD-START.md                  # Entry point: "Start here"
│   ├── REQUIREMENTS-TEMPLATE.md       # Machine-executable requirements format
│   ├── DEVELOPMENT-PROCESS.md         # The 4-phase process
│   └── SERVICE-MAP.md                 # Service inventory with responsibilities
└── .claude/skills/                    # Custom skills for this project
    ├── requirements-discovery/        # Tailored to this project's patterns
    │   └── SKILL.md
    └── develop-and-test/              # Tailored to this project's test infrastructure
        └── SKILL.md
```

## Analysis Process

### Step 1: Codebase Reconnaissance

Spend significant time understanding before generating anything:

1. **Identify the architecture pattern:**
   - Monolith? Microservices? Serverless? Monorepo?
   - How do services communicate? (HTTP, message bus, events, gRPC)
   - What's the database strategy? (shared DB, per-service DB, gateway)

2. **Map the service inventory:**
   - List every deployable unit
   - Identify ports, entry points, health checks
   - Map dependencies between services

3. **Identify the service skeleton:**
   - Read 2-3 services' entry points
   - Extract the common initialization pattern
   - Document: what's the same, what varies

4. **Understand the data layer:**
   - Database type (PostgreSQL, MongoDB, DynamoDB, etc.)
   - ORM or raw queries?
   - Migration strategy
   - Table/collection ownership model

5. **Map the event/contract system (if any):**
   - How are events defined? (Protobuf, JSON Schema, Zod, TypeScript interfaces)
   - Where do event definitions live?
   - Versioning strategy (breaking changes, backwards compat)

6. **Catalog the testing approach:**
   - Testing framework (vitest, jest, pytest, go test)
   - Where do tests live? (co-located, separate directory)
   - Integration test infrastructure (docker-compose, test containers)
   - CI/CD pipeline

7. **Identify the deployment pipeline:**
   - How does code get to production?
   - Branching strategy
   - Environment separation (dev/staging/prod)

### Step 2: Generate CLAUDE.md

Create a CLAUDE.md for the repo root. Include:

```markdown
# CLAUDE.md

## Project Overview
[1 paragraph: what this project does, who it's for]

## Architecture
[Diagram showing services, communication, data flow]

## Build & Development Commands
[Every command a developer needs, with explanations]

## Architecture Patterns
[The patterns that are MANDATORY — not suggestions, rules]

## Key Conventions
[Naming, file structure, error handling, logging]

## Important Files (DO NOT refactor)
[Critical files that must be preserved exactly]

## Environment Variables
[Required vars with descriptions]

## Testing
[How to run tests, what framework, where tests live]

## Deployment
[How code gets to production]
```

**Quality standard:** A developer reading ONLY this file should understand enough to make changes without breaking things.

### Step 3: Generate Service Map

Document every service with:

| Service | Port | Subscribes To | Publishes | Tables (write) | Tables (read) |
|---------|------|---------------|-----------|----------------|---------------|

### Step 4: Generate Requirements Template

Adapt the generic requirements template to this project's patterns:

- If the project uses RabbitMQ → include message contract section with Zod
- If the project uses gRPC → include proto definition section
- If the project uses REST only → include OpenAPI schema section
- If the project uses shared DB → include table ownership section
- If the project uses per-service DB → include migration section per service
- Match the project's testing approach in the acceptance criteria section

**The template must map 1:1 to code artifacts for THIS project.**

### Step 5: Generate Custom Skills

Create 2 skills tailored to this project:

**1. requirements-discovery** (customized):
- Reference this project's architecture patterns in the questions
- Include this project's event catalog in Round 2
- Include this project's table catalog in Round 2
- Reference this project's conventions in Round 3

**2. develop-and-test** (customized):
- Use this project's build commands
- Use this project's testing infrastructure
- Reference this project's service skeleton
- Include this project's deployment pipeline

### Step 6: Generate Cold-Start Doc

Create `docs/COLD-START.md`:

```markdown
# Cold Start — [Project Name]

## For Developers Using Claude Code

### Quick Setup (5 minutes)
1. Clone this repo
2. Install dependencies: [command]
3. Set up environment: [steps]
4. Tell Claude Code: "Read CLAUDE.md and docs/COLD-START.md"

### What Claude Code Can Do For You
- `/requirements-discovery` — Define a new feature interactively
- `/develop-and-test` — Build and test from a requirements doc
- [Other custom skills]

### Architecture at a Glance
[Simplified diagram — 10 lines max]

### Key Docs to Read First
1. [Link to most important doc]
2. [Link to second most important doc]
3. [Link to third most important doc]

### Dev Environment
[How to set up dev infrastructure for testing]

### Common Tasks
| Task | Command/Skill |
|------|--------------|
| Build a new feature | `/requirements-discovery` then `/develop-and-test` |
| Add a new service | Same, with "new-service" type in requirements |
| Fix a bug | Describe the bug, Claude Code will investigate |
| Deploy to dev | `git push origin dev` |
| Deploy to prod | Merge `dev` → `main` |
```

### Step 7: Generate Development Process Doc

Adapt the 4-phase process to this project:

```
Phase 1: Requirements Discovery (interactive)
Phase 2: Architecture Validation (semi-autonomous)
Phase 3: Develop & Test (autonomous with checkpoints)
Phase 4: Deploy & Verify (semi-autonomous)
```

Customize each phase with:
- This project's build commands
- This project's test infrastructure
- This project's deployment pipeline
- This project's review process

## Validation

Before delivering the package:

- [ ] CLAUDE.md accurately describes the architecture (cross-check with actual code)
- [ ] Service map is complete (no missing services)
- [ ] Requirements template sections map to actual code artifacts
- [ ] Custom skills reference correct file paths and patterns
- [ ] Cold-start doc can be followed by someone with zero context
- [ ] Build commands in all docs actually work
- [ ] No references to other projects' patterns (this is self-contained)

## Adaptability

This skill works for:
- **Node.js/TypeScript microservices** (RabbitMQ, Kafka, HTTP)
- **Python microservices** (FastAPI, Flask, Celery)
- **Go microservices** (gRPC, NATS, HTTP)
- **Java/Spring microservices** (Spring Cloud, Kafka)
- **Serverless architectures** (Lambda, Cloud Functions)
- **Monoliths being extracted to microservices**

The key principle is the same regardless of stack: **identify the repeating skeleton, document it, and make requirements map to code artifacts.**
