# Git hooks — the substrate staleness gate

`pre-commit` is the **lockstep enforcer**: it blocks a commit when a *structural*
change is staged (contracts/schema/topology, or agents/skills) without the matching
knowledge-layer doc also staged. This is what keeps code and the context store from
drifting **without anyone having to remember to ask** — the harness runs it, not the
agent. (Doctrine: enforce with a hook, not documentation.)

## Activate — automatic (self-arming)
`core.hooksPath` is **local git config and is never committed**, so a fresh clone has
the `pre-commit` file but git won't run it until something points git at this dir.
That "something" is **`ensure-gate.sh`**, wired as a **SessionStart hook** in
`.claude/settings.json`: the first time any agent opens this repo, it runs
`git config core.hooksPath .claude/hooks` (idempotent, non-destructive). No one has to
remember the command — the every-clone half has its own carrier.

Manual equivalent (if you don't use the SessionStart hook):
```sh
git config core.hooksPath .claude/hooks
chmod +x .claude/hooks/pre-commit
```
`df-context-store` also arms it on emit (non-destructively — see below).

## What it catches (and what it can't)
- **Catches (mechanical):** a contract/schema/migration or a new/renamed service
  changed but no `SERVICE-MAP.md` / `DATA-FLOW.md` / `<service>/CLAUDE.md` staged;
  an agent/skill changed but `agents/README.md` not updated.
- **Cannot catch (semantic):** "you found a root cause / made a decision and didn't
  record it." That stays with `knowledge-keeper` + the `commit-sync` skill. The gate
  is the hard floor; the skill is the rest.

## Tuning
Edit the **TRIGGER TABLE** block in `pre-commit` for this repo's layout. Each rule:
*if a trigger glob is staged and no required doc is staged → block.* Start
conservative; widen as conventions firm up.

## Escape hatches
- One commit: `git commit --no-verify`
- This repo: `SUBSTRATE_GATE=off git commit ...` (or unset `core.hooksPath`)
- Chain an existing hook (husky, etc.): put it at `.claude/hooks/pre-commit.local`
  (executable) — the gate runs it first and respects its exit code.

## Conflict note
`core.hooksPath` makes git use **only** this directory for hooks. If the repo already
sets `core.hooksPath` or uses husky, do **not** overwrite it — install the gate as
`.claude/hooks/pre-commit.local` under the existing path instead, or chain via the
`.local` mechanism above.
