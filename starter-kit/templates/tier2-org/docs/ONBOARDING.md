# Onboarding — from nothing to a running agent

Written for someone who has never seen any of this. Seven steps, about ten minutes.

## 1. Prerequisites

`git`, `jq`, and an agent harness (e.g. Claude Code). `gh` (GitHub CLI) helps but is
optional. You need read access to this repo; Tier 1 is public.

## 2. Clone and install the shared environment

```sh
git clone https://github.com/__ORG_REPO__.git
cd __ORG_LAYER_NAME__
bash install.sh --dry-run   # read the plan first
bash install.sh
```

The installer fetches Tier 1 at its pinned commit, symlinks the skills, copies the hooks,
verifies the result, and prints what it **cannot** do for you. Read that list — a green
install is not a complete setup.

## 3. Generate your own instance

```sh
bash scripts/new-instance.sh <your-instance-name> ~/Code
cd ~/Code/<your-instance-name>
bash install.sh
```

Your instance pins this repo by commit SHA, resolved at generation time. It holds only
what is yours.

## 4. Let your agent name itself

Start a session and ask the agent to choose a name. Set it in `instance.lock.json`
(`agentName`) and `export AGENT_NAME=<name>`. Deliberately not defaulted — a name that
arrived by default was never chosen. That name never becomes a release, image tag, or
ticket fixVersion.

## 5. Confirm your MCP tool namespace

List the tools available in your agent session. There is no single prefix — the name
depends on how your machine connects. If nothing resolves or it is ambiguous, ask — a
wrong prefix looks exactly like a missing tool.

## 6. Wire the hooks

Merge the installed hooks into `~/.claude/settings.json` (see `hooks/README.md`). Merge
into existing arrays; never overwrite the file.

## 7. Start a NEW session

Hooks and MCP manifests are read once, at session start. Nothing you just installed is
visible in a session that was already running.

---

**On a cloud dev environment** (e.g. a Coder workspace): clone onto a mount that survives
a reset rather than into `~`. Recovery after a reset is then just `bash install.sh
--offline`.
