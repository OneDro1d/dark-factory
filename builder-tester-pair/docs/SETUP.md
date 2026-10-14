# Setting up a builder/tester pair

A new pair takes about 20 minutes. You do it once per project; several pairs can share one copy of this kit, each
with its own `pair.yaml` and shared folder.

## What you need

| Item | Builder workspace | Tester workspace |
|---|---|---|
| A workspace (e.g. a Coder workspace) | yes | yes, a separate one |
| A shared folder both mount (e.g. Azure Files, NFS) | mounted | mounted, same path |
| Claude Code, `tmux`, `git`, `gh`, Python 3 | yes | yes |
| GitHub access to your repos (`gh auth status`) | yes | yes (read) |
| MCP hub for Teams / Slack / Jira / Engram (optional) | signed in | signed in, separately |
| Argus end-to-end checker (optional) | runner tokens only | author tokens only |

## The short way: one command

```bash
git clone <repo> <shared>/builder-tester-agents && cd <shared>/builder-tester-agents
./setup              # asks every question ONE at a time (Enter keeps the measured/derived default), then runs
                     # each step below, asking before each. Stop any time; run ./setup again to continue.
./setup --steps      # on the second workspace (same pair.yaml): only the steps
```

Prefer Claude? Run `/pair-setup` instead: it asks the same questions from the same list
(`kit/lib/questions.yaml`), one at a time, and looks ids up for you. Each workspace gets only its own role's rules
and its own start command (`builder.start_command` / `tester.start_command`).

### Make sure both workspaces exist

`./setup` runs `kit/scripts/ensure-workspace.sh` early (after the questions, before install): on the builder it
checks the **tester's** workspace, on the tester the **builder's** (`both` when the host matches neither). The rule:
**if it can create the workspace by itself, it creates it; else it prints the steps.**

```bash
bash kit/scripts/ensure-workspace.sh [builder|tester|both] [--yes] [--dry-run]    # --selftest uses a fake coder
```

- **Can create** = `coder` on PATH, `coder whoami` succeeds, `coder list -o json` works and
  `<role>.coder_template` is in `coder templates list`. It then shows the exact
  `coder create <owner.coder_user>/<role>.workspace --template … --parameter k=v … --yes`, asks `[y/N]` (or
  `--yes`), creates it, waits (bounded) until it is running, and prints the next step:
  `cd <shared_root>/builder-tester-agents && ./setup --steps` in that workspace.
- **Cannot** (not signed in — the builder normally is not —, no template set, template not visible, no permission):
  numbered steps for a person — admin onboarding (`<role>.onboarding`, shown with its apply command, never run),
  `coder login <owner.coder_url>`, the exact `coder create …`, `./setup --steps` there, then `coder logout --yes`
  on the builder (the builder must not reach the tester).
- Settings: `owner.coder_user`, `owner.coder_url`, `<role>.coder_template`, `<role>.coder_parameters` (map),
  `<role>.onboarding`. Exit 0 = exists / created, 2 = steps printed (setup carries on), 1 = error.
- It never runs `coder delete` / `coder ssh`, kubectl or az, and never prints coder's output (no tokens).

### Deploy approvals — the owner adds this tool, not an agent

`deploy-gate` lets a deploy through only inside an approval window the OWNER opened. The tool that opens windows,
`kit/bin/approve-deploy`, is deliberately not written by any agent (the guards block agents from creating or
editing approval tools). The owner copies their organisation's approved version into `kit/bin/` themselves (or
writes one: `approve-deploy <scope> [minutes]`, `--list`, `--revoke-all`; scope at least 6 characters; at most 480
minutes; files under `paths.approvals` written with umask 077) and re-runs `./install.sh`. `./setup` reminds you.

**What the approval window is, and is not.** The read-only cluster credential (`k8s/agent-readonly.yaml`, applied by the owner with
`kit/scripts/make-agent-kubeconfig.sh`) is the BOUNDARY: a token that cannot write fails every write however it is spelled. The approval window and the
deploy-gate regexes are a TRIPWIRE on top, not a boundary:
- `deploy-gate` honours any well-formed `appr-*.json` in `paths.approvals` (by, created, unexpired expires, a scope of 6+ characters); it cannot tell who
  wrote the file. If the builder's Linux user can write that directory, the party the window restrains can open its own window. This is the case when
  the ledger lives on a shared disk that both workspaces mount under the same uid (mode bits then isolate nothing, `drwx------` included).
- Check it for YOUR deployment, as the builder's user: `test -w <paths.approvals> && echo "WRITABLE: the window is only a tripwire here"`. If it is
  writable, put `paths.approvals` where the builder cannot write (a different owner, or a different filesystem the builder mounts read-only), or accept
  that the control is the read-only credential plus the builder's own instructions.
- The 6-character minimum for a scope is enforced in BOTH `deploy-gate.py` and the chat approval step, deliberately. Consequence: a namespace such as
  `dev`, `api` or `prod` can never be approved by any path, chat or command. If you need that, change the bound in both places; do not change one.

## Steps

1. **Clone the kit into the shared folder** (once):
   `git clone <repo> <shared>/builder-tester-agents`
2. **Answer the setup questions**, either:
   - in Claude: open Claude in the builder workspace inside `<shared>` and run `/pair-setup`; or
   - in the terminal: `cd <shared>/builder-tester-agents && ./install.sh` (asks the questions when there's no
     `pair.yaml` yet).
   The answers go into `<shared>/pair.yaml`: project name, owner, the two agents' names, workspaces and hostnames,
   repos (as many as you need), Teams/Slack/Jira ids, memory space names, schedule. Edit it any time and re-run
   `./setup-pair render` in each workspace.
3. **Create the memory spaces** (Engram): `/pair-setup` does it; or `./setup-pair engram` lists them to create by hand.
4. **Connect the repos**: `./setup-pair repos` checks access.
   **Knowledge base** (optional): set the `knowledge:` section of pair.yaml (which branch it learns from, the areas;
   defaults work), then `./setup-pair knowledge init` in the builder workspace, then `/knowledge-build` in the
   builder's Claude session. It grows by itself after that (see `docs/KNOWLEDGE.md`).
5. **Install in the builder workspace**: `./install.sh` (links skills, installs and registers hooks with their
   timeouts, installs the reviewer and patrol agents into `~/.claude/agents/`, checks the Dark Factory skills, sets the
   read-only kubeconfig, renders the builder's listener config and start command, runs the checks).
   Options and switches:
   - `./install.sh --pack <name>` also installs an optional hook pack (`packs/<name>/hooks.json`).
   - `rules.reviewer` (default `adversary`) names the reviewer agent: `agents/adversary.md` is installed as
     `~/.claude/agents/<rules.reviewer>.md`. `agents/patrol.md` is the read-only patrol.
   - `dashboard.artifact_url`: the `dashboard-artifactdata-allow` hook auto-approves only the builder's snapshot
     writes to that page, so it stays live unattended.
   - `dark_factory.enabled: true`: install checks every skill in `dark_factory.skills` (+ `loop_skill`) exists in
     `~/.claude/skills` and lists the missing ones; `dark_factory.skills_dir` is linked in first.
     `dark_factory.stage_gate: true` also registers the `df-stage-gate` and `df-dispatch-subagents-reminder` hooks.
6. **Install in the tester workspace**: same command there.
7. **Wall them off** (builder workspace): `coder logout --yes`. Put Argus author tokens only in the tester's home.
   **Read-only kubectl for the agents** (strongly recommended): run `bash kit/scripts/make-agent-kubeconfig.sh
   --context <ctx> --namespace <ns-you-control>`. It applies nothing; it prints the commands for YOU to run with your
   own identity (create the `k8s/agent-readonly.yaml` ServiceAccount, mint a 30-day `~/.kube/agent-readonly.conf`).
   Copy that file into each workspace's `~/.kube/` and re-run `./install.sh`: it sets `env.KUBECONFIG` in
   settings.json so the agents' cluster writes fail with 403. Without it install.sh warns loudly every run.
   Cluster caps `kubectl create token` (e.g. 24h)? Add `--no-expiry`: it prints the owner's commands for a
   non-expiring token Secret (`k8s/agent-readonly-token.yaml`), verifies it, streams the file to the other workspace
   over `coder ssh <owner.coder_user>/<workspace>` without printing it, and prints the undo (delete the Secret).
8. **Sign in to your MCP hub in each workspace, separately**: `bash kit/scripts/hub-login.sh` (settings: `hub:` in
   pair.yaml). It registers the hub's MCP server for this workspace's agent with its own isolated home folder, runs
   a device-code sign-in, and checks the login was saved (presence only). Never copy a login between workspaces.
9. **Start them**: in each workspace `bash <shared>/builder-tester-agents/kit/scripts/start-agent.sh`.
   If the agent stops at a question on screen, answer it; then detach with Ctrl-b, d.
10. **Check**: `./setup-pair check` in each workspace (all PASS), and send `<tester-name> restart` in your Teams
    self-chat — each agent posts a "Started" report.
11. **Prove the loop**: send one small real request to the tester and watch spec → build → local test →
    "deploy or review first?" arrive, with every step in your change channel.
12. **Your own dashboard — every person publishes their own private copy** (optional). The kit ships the page,
    `templates/dashboard/control-room.html`, never a URL. In **your own** Claude session: load the
    `artifact-capabilities` skill, then publish that file with the Artifact tool as a **new, private** artifact
    (no `url`), declaring the capabilities named in the page's header comment:
    `capabilities: {"db": {"rules": [{"path": "", "write": "admin"}]}}`. Put the URL it returns into **your**
    `pair.yaml` as `dashboard.artifact_url` and re-run `./setup-pair render` in each workspace (`/pair-setup` step
    6b does all of this). `./setup-pair check` then shows `dashboard: your own page <url>`.
    - The URL is **per person, not per team**: never reuse someone else's URL (an example file, a teammate's
      pair.yaml). The builder would write your pair's status into their page, and the allow hook would approve it.
    - Empty `dashboard.artifact_url` = no dashboard; nothing is pushed.
    - How it works: each builder tick runs `kit/bin/dashboard-live-snapshot` and writes one document
      `snapshots/<ts>` with ArtifactData; the page shows the newest one live (`db` capability, owner-only writes).
      Titles and names (project, owner, builder, tester) and the stale warning (`schedule.stall_minutes`, else 45)
      come from the snapshot; nothing person-specific is in the HTML.

## Two ways to deploy: separate workspaces or one (`guard.workspace_mode`)

| `guard.workspace_mode` | Use when | What it means |
|---|---|---|
| `separate` (default) | builder and tester each have their own workspace | The hand-over tools demand proof of an untampered environment (same namespaces as PID 1) and fail closed. The wall between the agents is a real one. |
| `single` | both agents run in ONE workspace | The same check compares with the oldest readable process of the agent's own user, because one agent can never read PID 1. It still catches a process that really unshared. The agents share an account's rights, so treat it as a tripwire, not a wall; keep the guards below on. |

Switching is one line in `pair.yaml` plus the steps in the next two sections; no code changes.

## The tester in the SAME workspace (`guard.workspace_mode: single`, as another Linux user)

Until a tester workspace exists you can run the tester next to the builder. It is weaker than two workspaces — treat
a PASS from it as provisional — but the tester's tests, tokens and sign-ins stay out of the builder's reach:

1. Give each role a Linux user in `pair.yaml`: `builder.user` (the current account), `tester.user` + `tester.uid`
   (fixed, e.g. 2101), `tester.agent_home` (private home, mode 700), and set `tester.host` to the SAME host pattern as the
   builder. Roles are then told apart by user (`pairconf.role`).
2. `paths.share_group: pairshare` and `guard.block_privilege_escalation: true` (the builder may not `sudo`/`su` or open
   the tester's home).
3. Owner, with sudo: `bash kit/scripts/tester-users.sh` (idempotent; re-run after a pod rebuild — users vanish with the pod,
   the home folders and their ownership survive because the uid is fixed).
4. Install the tester AS that user: `sudo -u <tester.user> -H env PAIR_CONFIG=<pair.yaml> bash install.sh`, then its own
   sign-ins (Claude, `gh`, Argus author tokens — device codes, you approve), then `start-agent.sh` as that user.

Limit: the account still has passwordless sudo, which a guard hook cannot make unreachable. That is why this is a stand-in.

### Moving the tester to its own workspace later

Nothing is rebuilt. Create the workspace, then: (a) in `pair.yaml` set `tester.host` to `coder-<new workspace id>-*`, delete
`tester.user`, `tester.uid`, `paths.share_group` and `guard.block_privilege_escalation`; (b) in the new workspace run
`./setup --steps` (same shared folder, so the same `pair.yaml`); (c) sign the tester in there; (d) stop the tester here
(`tmux kill-session -t watchdog-<name>; tmux kill-session -t <name>` as that user) and remove its user and home.
The builder side needs only `./setup-pair render` and a restart.

## A brand-new or rebuilt workspace

A workspace's home folder is often recreated on rebuild (e.g. a Coder home on local disk), while the shared folder
survives. With the kit, everything that defines the pair lives on the shared folder — `pair.yaml`, the kit itself,
the ledger (`paths.ledger`) and the knowledge base (`paths.knowledge_*`) — so a rebuilt workspace only needs its
home-folder wiring and its own sign-ins back. In the rebuilt workspace, in this order:

| # | What | Command | Who |
|---|---|---|---|
| 1 | The shared folder is mounted at the same path (`paths.shared_root`) | `ls <shared>/pair.yaml <shared>/builder-tester-agents` | owner |
| 2 | Hooks, agents, skills, rules, start command, checks | `cd <shared>/builder-tester-agents && ./setup --steps` | owner |
| 3 | Optional: the agent's memory notes and helper binaries (no secrets) | `bash kit/scripts/restore-home.sh` (`--dry-run` first) | owner |
| 4 | The agent's OWN MCP hub sign-in | `bash kit/scripts/hub-login.sh` | owner (device code) |
| 5 | GitHub, as `identity.gh_account` | `gh auth login` then `gh auth status` | owner |
| 6 | The read-only kubeconfig | copy it back over `coder ssh` from the other workspace, or re-mint: `bash kit/scripts/make-agent-kubeconfig.sh [--no-expiry] …` (prints the owner's commands), then `./install.sh` | owner |
| 7 | The tester's end-to-end runner sign-in (if `argus.url` is set) | the runner's own sign-in, run by the owner in the tester workspace; tokens stay in that home | owner |
| 8 | Restart Claude, then check | `bash kit/scripts/start-agent.sh`, then `./setup-pair check` | owner |

Notes:
- **Hooks and MCP servers are read once at session start** — restart Claude after steps 2–4.
- `restore-home.sh` copies only `*.md` memory notes whose text does not look like a secret, into the memory folder
  Claude uses for `paths.shared_root` (the folder name is derived from that path — a folder under the wrong name is
  never loaded), plus binaries listed in `restore.bins`. It never overwrites. Before a planned rebuild, refresh the
  snapshot with `bash kit/scripts/restore-home.sh --save`.
- **Owner-only, never scripted by the kit**: every sign-in and token (steps 4–7), cloud CLI sign-ins (e.g.
  `aws sso login --use-device-code`), and git identity scoping beyond what `./setup` measures (an organisation may
  pin it with its own `includeIf` config and commit hooks). Repos not on any remote (local-only branches, a private
  instance repo) cannot be re-cloned: keep them on the shared folder, or as `git bundle` files there.

## Chat commands (your Teams self-chat)

| Send | Does |
|---|---|
| `<tester> — <ticket>: <change>` | the tester starts the spec |
| `<builder> — <ask>` | the builder answers, or forwards new work to the tester |
| `<name> restart` | a fresh copy of that agent in about 2 minutes (repeats are ignored) |
| `help-<name>` | the full command list |
| `approve <namespace> <minutes>` | opens a deploy window for the builder (max 120 min, used once) |
| `review <id>` / `deployed <id>` | diff and test summary before deploying / tell the builder you deployed |

## Where things are

| Path | What |
|---|---|
| `<shared>/pair.yaml` | all settings |
| `<ledger>/handoffs/<id>.json` | one file per piece of work, full history, integrity-checked |
| `<ledger>/handoffs/events.jsonl` | every step, in order (also posted to the change channel) |
| `<ledger>/specs/` | the tester's design files |
| `<ledger>/YYYY-MM-DD.jsonl` | every tool call by both agents |
| `<ledger>/guard-blocks.jsonl` | every time the guard blocked the builder |
| `~/.cache/agent-watchdog.log` | watchdog activity, per workspace |
| `~/.claude/agents/` | the reviewer (`<rules.reviewer>.md`) and `patrol.md` agents |
| `~/.kube/agent-readonly.conf` | the agents' read-only kubeconfig (owner-minted; time-bound, or non-expiring with `--no-expiry`) |
| `hub.home_dir` (default `~/.<hub.server_name>-home`) | this workspace's own MCP hub login (`kit/scripts/hub-login.sh`) |
| tester's `kits_dir` | the tester's working test files — its own home only, never the shared folder |
| `<ledger>/dashboard/*.json` | the Control Room datasets `dashboard-export` writes |

## Kit tools (`kit/bin/`, each has `--selftest`)

| Tool | What it does |
|---|---|
| `ledger [YYYY-MM-DD] [--all \| --needs \| --writes]` | what both agents did that day (default today): counts per agent, what changed something, what waits on the owner. Reads `<ledger>/<day>.jsonl`; summaries are masked again before printing. |
| `dashboard-export [out_dir]` | writes the Control Room datasets (default `<ledger>/dashboard/`): `actions`, `needs`, `approvals` (scope + expiry only, read-only), `prs` and `alerts` (via `gh` for each `repos[].github`; without `gh` it fails soft, and a failed alert query is `null`, never 0), `health`, `reports`, `scorecard`, `testruns`, `requirements`, `loops`. Every string is masked, then the dataset is scanned and the export **refuses** if a secret shape remains. |
| `dashboard-live-snapshot [out_file]` | runs `dashboard-export` and folds it into one document (< 200 KB) for the live page (`dashboard.artifact_url`), adding `project`, `owner`, `builder`, `tester`, `stall_minutes`, `tick_minutes` so the page (`templates/dashboard/control-room.html`) hard-codes no names. Checked end to end by `dashboard-export --selftest`. |
| `podenv.py <ns> <var>…` · `--all-ns <var>…` · `--keys <ns> [pod]` | environment variables inside pods **without ever printing a value**: length, a same-value group (A, B, … — keyed per run, so not even a hash is left) and a placeholder flag; `--keys` lists names and lengths. `--all-ns` uses `repos[].sut_namespaces`. A failed query is reported as failed, never as zero pods. |
| `k8s-ready.py <ns>…` · `--all-ns` · or pipe `kubectl get pods --no-headers` in | readiness that can go both green and red: all containers ready and Running; finished Jobs counted apart; exit 1 on not-ready, a failed query, or no pods returned. |

Optional `repos[]` keys read by `dashboard-export`: `health_url` (probed; only the status code is recorded and the
row is labelled with the app name, never the URL), `health_expect` (default `"200"`), `health_insecure` (`true`
skips TLS verification for self-signed dev certs). `tester.private_dir`, when set, is also refused by `handoff` as a
location for deploy/rollback command files and design files.
