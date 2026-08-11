<!--
  MERGE this block into the target repo's root CLAUDE.md (under a top-level
  "## AI Agents & Context Store" section). It is the always-on carrier of the
  read-first protocol — a build-time skill scaffolds the substrate once, but THIS
  stanza (loaded every session because CLAUDE.md is) is what binds every future
  agent to read-first + dispatch + verify. Do not leave it only in the template.
-->

## AI Agents & Context Store (read before working)

This repo ships an agent inner-loop in `.claude/`. **Before any investigation,
feature, or review, read the context store first — do NOT re-scan the repo:**
`.claude/context/SERVICE-MAP.md` (where things live) → `DATA-FLOW.md` (data nodes,
authority, validation rules — read before any feature/contract/data change) →
`FINDINGS.md` (already-known bugs/root causes) → `DECISIONS.md` (ADRs) → the one
relevant `<service>/CLAUDE.md`. The hand-off contracts and the pure/effect +
verification rules are in `.claude/context/AGENT-CONTRACTS.md`.

**Dispatch the right subagent** (full map in `.claude/agents/README.md`):

| Request | Agents (in order) |
|---------|-------------------|
| "Find the bug" | `investigator` → `root-cause-analyzer` |
| "Explain the root cause" | `root-cause-analyzer` |
| "Implement this feature" | `feature-architect` → `implementer` → `validator` |
| "Review this change" | `validator` |
| Record a learning / commit | `knowledge-keeper`, then the `commit-sync` skill |

**Standing rules** (every agent honors):
- **Read the context store first**; stop reading as soon as you have enough.
- **No guessing** — cite `file:line`; **escalate** when evidence is missing.
- **Hand-offs are contracts** — a consumer **rejects** an incomplete hand-off
  (`contract-check`) instead of guessing. See `.claude/context/AGENT-CONTRACTS.md`.
- **Test-first** — tests derive from ACCEPTANCE as a RED list; don't weaken them.
- **Verify, don't trust** — re-run the evidence (literal test counts, `file:line`);
  no agent is its own auditor.
- After confirming a root cause or decision, have `knowledge-keeper` write it back
  so it is never re-investigated. **Never commit/push without explicit approval.**
- **Keep code and the context store in lockstep.** A `pre-commit` staleness gate
  (`.claude/hooks/pre-commit`) blocks commits that change contracts/schema/services
  or agents without updating the matching map/README. It **self-arms** each session
  via the `SessionStart` hook in `.claude/settings.json` (→ `.claude/hooks/ensure-gate.sh`),
  so a fresh clone activates it with no manual step. It catches *structural* drift
  only — you still record findings/decisions via `knowledge-keeper` + `commit-sync`.
