---
name: commit-sync
description: Commit workflow — before committing, sync the knowledge layer (context store, per-service CLAUDE.md, and the agents/skills routing README) to the change, then draft a proper commit message and push. Use for "commit", "commit and push", "ship this", "save my work". Always stops for explicit approval before pushing.
allowed-tools: Read, Edit, Bash, Grep, Glob
---

# commit-sync

Goal: never let code and the knowledge layer drift apart, and never push junk or secrets. One procedure: sync → message → confirm → commit → push.

## Step 1 — Review what changed
```bash
git status --porcelain
git diff --stat
git diff           # actually read it
```
Identify which services/contracts/agents/skills the change touches.

## Step 2 — Sync the knowledge layer (the "update skills and agents" part)
> The `pre-commit` staleness gate (`.claude/hooks/pre-commit`) enforces the
> *structural* floor automatically — it will **block** the commit if a contract/
> schema/service or an agent/skill changed without its map/README staged. This step
> is how you satisfy that gate, plus the semantic part it can't check (findings/
> decisions). Don't rely on `--no-verify` to skip it.

Apply the **context-management** skill (knowledge-keeper discipline). For this diff:
- Contract/routing-key/table/object-store-key changed → update the shared-models index `CLAUDE.md` + the service `CLAUDE.md` + `.claude/context/SERVICE-MAP.md` + `.claude/context/DATA-FLOW.md` (nodes/authority/rules if the data shape or ownership moved).
- A bug fixed / root cause confirmed → update its `F-###` in `.claude/context/FINDINGS.md` (status OPEN→FIXED, add the fixing commit).
- A design decision made → add a `D-###` to `.claude/context/DECISIONS.md`.
- **An agent or skill added/removed/renamed** → update `.claude/agents/README.md` (routing table) so it stays the source of truth.
- A `CLAUDE.md` claim the diff makes stale → fix it, cite the code.
Only touch what this change actually affects. Cite sources; no guessing.

## Step 3 — Safety gate (block on any hit)
```bash
git diff --cached -U0 | grep -nEi 'api[_-]?key|secret|password|token|sk-ant|BEGIN .*PRIVATE KEY|bearer ' || echo "no obvious secrets"
```
Also confirm no PII in fixtures/data. If anything trips, STOP and report — do not commit.

## Step 4 — Handle the gitignored knowledge files
If `.claude/**` and new `CLAUDE.md` files are gitignored in this repo, and the user wants them shared, **force-add explicitly** and say so:
```bash
git add -f .claude/agents .claude/skills .claude/context <service>/CLAUDE.md
```
Otherwise leave them local. Never silently change `.gitignore` — flag it and let the user decide.

## Step 5 — Branch + stage
- If on the default branch, create a feature branch first (never commit straight to default).
```bash
git branch --show-current
git add -A        # plus any -f from step 4
```

## Step 6 — Draft the message (conventional, why-focused)
```
<type>(<scope>): <imperative summary ≤72 chars>

<what changed and WHY — the problem it solves, not a file list>
<contracts/migrations touched; F-###/D-### references if any>

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```
`type` ∈ feat|fix|test|docs|refactor|chore. `scope` = service (e.g. `service-a`). Reference the issue/ticket key if known.

## Step 7 — Confirm, then commit + push
**Show the user the message + file list and get an explicit "yes" before pushing** (standing rule — "looks good" on code ≠ approval to push). Then:
```bash
git commit -m "$(cat <<'EOF'
...message...
EOF
)"
git push -u origin <branch>
```
Report the commit SHA + branch. Do not open a PR or merge unless asked.

## Rules
- **Never push without explicit approval.** Never force-push.
- Don't squash shared history; follow the repo's merge model.
- If tests exist for the touched code, run them (or hand to `validator`) before proposing the commit.
