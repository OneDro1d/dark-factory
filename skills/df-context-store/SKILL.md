---
name: df-context-store
description: Dark Factory Stage 0.5 — scaffold a repo's in-repo agent inner-loop substrate (read-first context store + single-responsibility agents + checkable hand-off contracts + commit gate) from the proven template, populate it from the real codebase, and verify it. Use when bootstrapping a repo for DF work, running a DF build, or adding the agent substrate to an existing repo. Triggers on "context store", "agent substrate", "inner loop", "bootstrap agents", "df stage 0.5".
allowed-tools: Read, Write, Edit, Bash, Grep, Glob
---

# df-context-store — plant the inner-loop substrate (DF Stage 0.5)

Goal: give the repo a **persistent, in-repo, read-first agent substrate** so analysis
is done once and reused, hand-offs can't silently degrade, and nothing ships
unverified. This is the inner-loop complement to the heavy DF build stages — the
build injects rigor at the seams; this is what *lives in the repo* and binds every
future session. It runs between Stage 0 (Frame) and Stage 1 (PO), and again on
demand to refresh.

Template (source of truth): the `substrate-template/` directory bundled alongside
this skill (`skills/df-context-store/substrate-template/`).

## Procedure

1. **Emit the payload.** Copy `substrate-template/dotclaude/` into the target repo
   as `.claude/` (agents + context store + `hooks/` + `contract-check` + `commit-sync`
   + `AGENT-CONTRACTS.md`). Don't overwrite an existing populated store — merge.
2. **Populate from source, don't invent.**
   - `.claude/context/SERVICE-MAP.md` — the structural map (services/db/queue/API +
     flows), generated from the real codebase (use `service-mapper`).
   - `.claude/context/DATA-FLOW.md` — the data-transform view: data nodes
     (schema/origin/**authority**/class), the transform graph (`pure|effect`), and
     the validation rules (`LOCAL` reject / `GLOBAL` reconcile). Populate nodes +
     authority from source; leave rules you can't yet cite as marked skeletons.
   - Leave `FINDINGS.md`/`DECISIONS.md` as clean skeletons that accumulate as the
     repo is worked. Fill per-service `<service>/CLAUDE.md` stubs only where verified
     (`file:line`).
3. **Wire the always-on carrier.** Merge `substrate-template/CLAUDE-stanza.md` into
   the repo's root `CLAUDE.md` (read-first/dispatch/verify rules) — this is what binds
   every session, not the one-time scaffold.
4. **Arm the lockstep gate + make it self-arming (the every-commit half).** The gate
   can't drift code from the context store silently:
   - `chmod +x .claude/hooks/pre-commit .claude/hooks/ensure-gate.sh`
   - **Self-arm carrier:** merge the `SessionStart` hook from `substrate-template/dotclaude/settings.json`
     into the repo's `.claude/settings.json` (create it if absent; if it exists,
     add the `SessionStart` entry — do **not** clobber existing hooks). This runs
     `ensure-gate.sh` on every session so a fresh clone activates the gate with no
     manual step. (`core.hooksPath` is local git config and never travels in a commit —
     the SessionStart hook is what carries the every-clone half.)
   - **Arm it now (non-destructive):** if the repo has **no** existing `core.hooksPath`
     and **no** husky, run `git config core.hooksPath .claude/hooks` (or just run
     `bash .claude/hooks/ensure-gate.sh`, which does exactly this safely). If one
     already exists, do **not** overwrite it — install the gate as
     `.claude/hooks/pre-commit.local` under the existing path (it chains). Say which
     path you took.
5. **Verify (acceptance).** Run `bash substrate-template/verify-substrate.sh`
   (from this skill dir) against the template, and for an emitted repo confirm: required files present, no
   leftover template placeholders in `SERVICE-MAP`/`DATA-FLOW` (they're populated), the
   `contract-check` suite is green, the gate is executable + actually blocks an
   undocumented structural change, and the CLAUDE.md stanza is merged. Green is the
   bar; report the literal check counts.

## Outputs
- `.claude/{agents,context,hooks,skills/contract-check,skills/commit-sync}` in the target repo.
- A read-first stanza merged into the repo's `CLAUDE.md`.
- A populated `SERVICE-MAP.md` + `DATA-FLOW.md`; clean `FINDINGS.md`/`DECISIONS.md` skeletons.
- An armed `pre-commit` staleness gate (`core.hooksPath` set, or chained via `.local`),
  self-arming on future clones via the `SessionStart` → `ensure-gate.sh` hook merged
  into `.claude/settings.json`.

## Rules
- **Populate, don't fabricate** — `SERVICE-MAP` entries cite real code; unknowns are
  marked, not guessed (same discipline the agents enforce).
- **Idempotent** — re-running merges/refreshes; it must not duplicate entries or
  clobber an accumulated `FINDINGS`/`DECISIONS` ledger.
- **Generic-in, specific-out** — the template is project-neutral; the emitted
  substrate is tailored to THIS repo. Don't ship template placeholders into a repo.
- Referenced by `dark-factory-build` as Stage 0.5. An organisation layer may also call this
  as the substrate step of its own cold-start generator where that toolchain is present —
  optional integration, not required.
