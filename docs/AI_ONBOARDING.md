# AI Assistant Onboarding Guide

This document is written specifically for AI assistants (Claude Code, GitHub Copilot, and similar tools) onboarding to this codebase. Human developers may also find it useful as an orientation map.

---

## Read these documents first (in order)

1. **`CLAUDE.md`** — Project overview, tech stack, dev commands, conventions, and known AI gotchas. Start here.
2. **`docs/ARCHITECTURE.md`** — System design, component interactions, and key design decisions.
3. **`.github/CONTRIBUTING.md`** — Branch strategy, review model, and Definition of Done.
4. **Recent git log** — `git log --oneline -20` shows what has been changing recently.

Do not begin making changes until you have read at least items 1 and 3.

---

## Repository structure

```
.
├── CLAUDE.md                    # AI context and dev guide (canonical)
├── sonar-project.properties     # SonarCloud config — set projectKey before first scan
├── .env.example                 # Required environment variables — copy to .env locally
├── .github/
│   ├── CONTRIBUTING.md          # Review model, branch strategy, Definition of Done
│   ├── CODEOWNERS               # Auto-requested reviewers
│   ├── dependabot.yml           # Automated dependency updates
│   ├── pull_request_template.md # PR checklist — fill in completely
│   └── ISSUE_TEMPLATE/          # Bug and feature request templates
├── docs/
│   ├── ARCHITECTURE.md          # System design and design decisions
│   └── AI_ONBOARDING.md         # This file
└── README.md                    # Human-facing project intro and quick start
```

<!-- TODO: Add your project's source directories here with one-line descriptions.
Example:
├── src/
│   ├── api/        # HTTP handlers and routing
│   ├── domain/     # Business logic — no framework dependencies here
│   ├── infra/      # Database, messaging, external clients
│   └── config/     # Configuration loading and validation
└── tests/
    ├── unit/       # Fast, no I/O
    └── integration/ # Requires running dependencies
-->

---

## Before making any change, ask yourself

- [ ] Have I read `CLAUDE.md` and `docs/ARCHITECTURE.md`?
- [ ] Do the existing tests still pass after my change?
- [ ] Is code coverage maintained (Sonar quality gate or ≥80%)?
- [ ] Have I avoided committing secrets, credentials, or environment-specific config?
- [ ] If I changed architecture or conventions, have I updated `CLAUDE.md` and/or `docs/ARCHITECTURE.md`?
- [ ] Does my commit message describe *why*, not just *what*?

---

## Common gotchas

<!-- TODO: Fill this section in as you discover things that AI assistants commonly get wrong.
Examples of what to document:
- "Do not use X library for Y — we use Z instead because [reason]"
- "The config loader expects environment variables in SCREAMING_SNAKE_CASE with a PROJECT_ prefix"
- "Integration tests require a running instance of the database — see ARCHITECTURE.md for local setup"
-->

*No project-specific gotchas documented yet. Add them here as you encounter them.*

---

## Effective prompts for this codebase

<!-- TODO: Document prompt patterns that produce reliable results.
Example:
"Add a new endpoint for X following the pattern in src/api/existing_handler.go"
→ AI should: create handler, register route, add unit test, update OpenAPI spec

"Debug why the integration test for X is flaky"
→ AI should: check for timing issues, shared state, missing cleanup in test teardown
-->

*No prompt library yet. Add examples here as useful patterns emerge.*

---

## Getting help

- **Architecture questions** — Read `docs/ARCHITECTURE.md` first; check git log for context on recent decisions.
- **Conventions questions** — Read `CLAUDE.md`; if the answer isn't there, ask a team member and then update `CLAUDE.md` with the answer.
- **Test failures** — Run tests locally before assuming the failure is pre-existing.
- **Coverage drops** — Check the Sonar dashboard or run coverage locally; do not merge with a coverage regression.
