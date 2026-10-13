# builder-tester-agents

Two Claude Code agents per project, working the way a good team does: a **tester** that owns what "done" means and
a **builder** that only builds to it. The tester (product owner + architect + tester) agrees each requirement with
the requester, writes the acceptance criteria and design, writes tests the builder never sees, and judges every
result. The builder writes the code and opens a PR. You approve deploys and merges. The agents pass work to each
other through a shared hand-over log, so nobody copies and pastes between sessions, and every step is posted to
your team's change channel.

Works for any project: you choose the agent names, repos, chat channels, ticket labels and memory spaces in one
settings file, `pair.yaml`. Nothing about any particular project is built in.

## Set up (about 20 minutes)

You need two workspaces (one per agent) that mount the same shared folder, with Claude Code, `tmux`, `git`, `gh`
and Python 3 installed.

```bash
# in the builder's workspace
git clone <this repo> <shared-folder>/builder-tester-agents
cd <shared-folder>/builder-tester-agents
./setup               # asks every question one at a time, shows a summary to confirm, then runs each setup step

# in the tester's workspace (same shared folder, so it finds the same pair.yaml)
cd <shared-folder>/builder-tester-agents && ./setup --steps    # no questions; just the steps
```
`./setup` runs `install.sh` as one of its steps; run `install.sh` on its own only to re-link hooks and skills.

Prefer to be guided? Open Claude in the builder's workspace and run **`/pair-setup`**: it asks the questions, looks
up your Teams/Slack/Jira ids, checks access to your repos, creates the memory (Engram) spaces, writes `pair.yaml`
and runs the installer. Then it lists the few sign-in steps only you can do.

## One file holds everything: `pair.yaml`

Every choice for your pair lives in one settings file, `<shared-folder>/pair.yaml`; nothing about any project is
built into the code. It has a section per topic — `project`, `owner`, `builder`, `tester`, `paths`, `repos` (as
many as you need), `teams`, `slack`, `jira`, `engram`, `argus`, `schedule`, `rules`, `dashboard` — and every key is
explained in [`pair.example.yaml`](pair.example.yaml). To change anything: edit `pair.yaml`, then run
`./setup-pair render` in each workspace (and restart the agent with `<name> restart`).

## Is my setup right?

Run this in each workspace:

```bash
./setup-pair check
```

It checks the settings file, this workspace's role, the shared folder, the tools, the guard hooks, the rendered
files, the watchdog and agent sessions, the builder's sign-out and key separation, and connector sign-ins. Each line
says PASS, WARN or FAIL, with the fix next to it. The result is also saved to `<ledger>/setup/<role>.json` (with the
time and the kit version), so you can see from either workspace when each side last passed.

Full guide: [docs/SETUP.md](docs/SETUP.md) · Problems: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) ·
How the knowledge base works: [docs/KNOWLEDGE.md](docs/KNOWLEDGE.md) — set it up with `./setup-pair knowledge init`
then `/knowledge-build`; every setting is in the `knowledge:` section of pair.yaml
Every rule the agents follow, and how to add your own: [docs/RULES.md](docs/RULES.md) — org packs (`extends:`), `rules.standing`, parity check
The builder/tester model, point by point, and where the kit does each: [docs/MODEL.md](docs/MODEL.md)

## How a piece of work flows

1. Someone asks the tester (`<tester> — PAY-12: refuse over-limit payments`), or the builder forwards a request word
   for word.
2. The tester clarifies with the requester and hands the builder a spec: acceptance criteria + a short design.
3. The builder restates it, builds exactly that with unit tests, and hands in a PR pinned to one commit.
4. The tester tests that commit locally (no deploy). A failure goes back to the builder (3 rounds max).
5. You choose: deploy now, or review first. The builder deploys only inside the window you approve.
6. The tester rechecks live (through Argus, if you use it). You review and merge. Agents never merge.

## What keeps it honest

- **Separate workspaces and keys**: the tester's tests and keys stay in its own workspace; the builder can't reach it.
- **The tester owns the acceptance**: only the tester can write or change a spec; edits afterwards are detected.
- **Expected answers come from the requirement**, never copied from the code, so a test can't pass on a bug.
- **Leaks are visible**: hidden marker values in tests are searched for in the builder's PRs before any PASS, and
  every blocked attempt by the builder is reported to you.
- **Always on**: a watchdog restarts an agent that stops and gives both a fresh start twice a day; you can restart
  either from chat (`<name> restart`).
- **Audit trail**: every hand-over step in the shared log and in your team's change channel.

## Layout

| Path | What |
|---|---|
| `setup` | the one command, per workspace (`--steps` on the second one) |
| `install.sh` | links hooks, agents and skills into `~/.claude` (one of `setup`'s steps) |
| `setup-pair` | `init` (questions → pair.yaml), `render`, `repos`, `engram`, `check` |
| `pair.example.yaml` | every setting, documented |
| `kit/bin/` | `handoff` (the loop), `canary` (leak markers), `restart-request`, `chat-approval`, `reqstatus`, `verdict`, `testrun`, `knowledge-refresh`, `board`, `ledger` (what the agents did), `dashboard-export` + `dashboard-live-snapshot` (the Control Room data), `podenv.py` / `k8s-ready.py` (safe pod checks) — see `docs/SETUP.md` § Kit tools |
| `kit/hooks/` | guards (no test reads by the builder, deploy approvals, secret safety) — see `kit/hooks/HOOKS.md` |
| `kit/scripts/` | `start-agent.sh`, `agent-watchdog.sh`, `local-verify.sh` |
| `templates/` | the agents' instructions, rendered from pair.yaml |
| `skills/` | `/pair-setup`, the chat listener, the tester's brief |
| `packs/` | optional add-ons for a specific organisation |

Credits: the builder/tester model follows Michal Bacia's design (two workspaces, the tester as product owner, the
builder kept blind to the tests).
