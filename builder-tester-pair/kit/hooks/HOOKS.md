# Generic hooks

Registered by `install.sh` from `hooks.json` (same list, machine-readable). Every hook reads `pair.yaml` through
`kit/lib/pairconf.py`; on a machine with no `pair.yaml` they do nothing. The role (builder / tester) comes from
the machine's hostname matched against `builder.host` / `tester.host`.

| File | Event | Matcher | What it does |
|---|---|---|---|
| `session-start.sh` | SessionStart | — | Tells the agent its role (builder or tester), the owner, the hand-over commands and the rules, with names from `pair.yaml`. Says nothing on other machines. |
| `action-ledger.py` | PreToolUse + PostToolUse | `*` | Writes every attempted and completed tool call to `<paths.ledger>/<date>.jsonl` (masked; the tester's arguments are never logged). While `pair.yaml` exists but cannot load, entries go to `~/.cache/builder-tester-agents/ledger-fallback/` with `config_error` set and the tester's privacy (program names only), instead of being dropped (they are in that workspace's home, not the shared ledger — the tester's `handoff list` does not see them). `--selftest`. |
| `pair-guard.py` | PreToolUse | `*` | The builder/tester wall: blocks the builder from the tester's tests (incl. `tester.private_dir`), credentials (over `coder ssh` or plain ssh/scp/rsync to `coder.<tester.workspace>`), workspace and pod; keeps the builder from changing who is builder/tester, who the owner is, or where the guards and the approval tool look (`owner`, hosts, `tester.*`, `paths.approvals`/`ledger`/`mcp_json`, `guard`, `extends`, `dashboard.artifact_url`, the Teams/Slack MCP server keys) in `pair.yaml` or any file its `extends:` pulls in, and from editing `.mcp.json`. With the Edit/Write tools only those keys are frozen; in a shell command, a segment that names a protected file (by any spelling, glob or symlink) may only be a read-only program (cat, grep, diff, git diff/log, cp it elsewhere…). It also blocks leaving the file empty or unparseable, and writing a second `pair.yaml` that would be found first; blocks `guard.blocked_hosts`; keeps deploy approvals the owner's; enforces the Teams post format and the bot marker on the owner's self-chat; blocks approval-shaped posts. Logs every builder block to `<paths.ledger>/guard-blocks.jsonl`. **Fails closed**: if `pair.yaml` cannot load (or the `~/.config/builder-tester-agents/pair.yaml` link points at nothing), only `pair*.yaml` stays readable/editable. `--selftest`. |
| `deploy-gate.py` | PreToolUse | `Bash` | Blocks cluster writes unless covered by a live approval window the owner opened; hands the command to the owner. Also treats as a deploy: `eval` in any spelling, `make … deploy|install|…`, text piped or fed to a shell it cannot read (`| env bash`, `bash -c "$(…)"`, `<(…)`, `/dev/stdin`, `sh < file`), and a script it cannot see. Relative scripts resolve against the event's cwd and plain `cd <dir>` steps; any other cd/pushd/subshell makes them fail closed. Text that only mentions a command (echo/grep/printf) is not a deploy. Fails closed: if `pair.yaml` cannot load, every shell command is blocked (the Read/Edit tools stay free to fix it). `--selftest`. |
| `secret-readback-guard.py` | PreToolUse | `Bash` | Blocks printing secret files (built-in paths + `guard.secret_paths`) and token-bearing git remote URLs. Fails closed: if `pair.yaml` exists but cannot load, every shell command is blocked until it loads. `--selftest`. |
| `outbound-verify-guard.py` | PreToolUse | `*` | Never blocks: before a Teams/Slack/Jira/email/PR post, adds a re-verification checklist and flags missing bot attribution (the `[bot — …]` marker counts) and broken HTML. A read-only `gh api` call (no method, no body) is not a send. `--selftest`. |
| `dashboard-artifactdata-allow.py` | PreToolUse | `ArtifactData` | Auto-approves ONLY the builder's writes to the `snapshots` collection of the page at `dashboard.artifact_url` (so the live dashboard does not go stale in unattended auto mode). Anything else gets no decision and goes through the normal permission flow. `--selftest`. |
| `post-deploy-retest.py` | PostToolUse | `Bash` | Never blocks: after a cluster write (kubectl apply/create/patch/scale/set/rollout restart…, helm upgrade/install, `kustomize build … \| kubectl apply`) touching a namespace in `repos[].infra`/`sut_namespaces` or an app in `repos[].app`/`services`, reminds: wait for the rollout, run `handoff deployed <id>`, and a deploy is not done until the tester's live PASS. With no namespaces/services listed it fires on every cluster write. `--selftest`. |
| `df-stage-gate.py` | PreToolUse | `Write\|Edit\|MultiEdit` | Dark Factory: blocks writing a stage doc (`docs/dark-factory/NN-*.md`) unless its owning `df-*` skill ran this session. **Registered only when `dark_factory.stage_gate: true`** (`DF_STAGE_GATE=off` disables). |
| `df-dispatch-subagents-reminder.py` | PreToolUse | `Agent\|Task` | Dark Factory: adds the promise + unforgeable-evidence contract to every sub-agent dispatch. **Registered only when `dark_factory.stage_gate: true`.** |

`ledger_common.py` is a shared module (masking, categories), not a hook; `install.sh` copies it and `pairconf.py`
next to the hooks.

## hooks.json fields

| Field | Meaning |
|---|---|
| `file`, `event`, `matcher` | the hook script in this folder, and where Claude Code calls it |
| `timeout` | seconds before Claude Code gives up on the hook (5 for guards and reminders, 10 for SessionStart and pair-guard) |
| `statusMessage` | optional text shown while the hook runs |
| `when` | optional dotted pair.yaml key: the hook is registered only while that setting is `true`, and unregistered again by the next `./install.sh` when it is not |

`install.sh` copies each hook into `~/.claude/hooks` (backing up a differing copy) and writes the entries into
`~/.claude/settings.json`; re-running it updates `timeout`/`statusMessage` on entries it registered before and leaves
settings.json untouched when nothing changed. `./install.sh --pack <name>` does the same for
`packs/<name>/hooks.json` (e.g. `--pack sample`).

Related tools in `kit/bin/`: `chat-approval` (turns the owner's "approve <namespace> <minutes>" chat message into
an approval window, after re-reading it through the MCP connector; `--selftest`) and the owner's approval command
(`approve-deploy`, run by the owner with `!`).

## pair.yaml keys these hooks read

| Key | Used by | Default |
|---|---|---|
| `builder.host`, `tester.host`, `builder.name`, `tester.name` | all | — |
| `owner.name`, `owner.short_name` | pair-guard, deploy-gate, session-start | first word of `owner.name` |
| `owner.teams_user_id`, `owner.slack_user_id` | chat-approval | — (chat approvals refused when empty) |
| `tester.workspace`, `tester.k8s_namespace`, `tester.kits_dir`, `tester.private_dir` | pair-guard | — |
| `paths.ledger`, `paths.approvals` | all | approvals = `<paths.ledger>/approvals` |
| `dashboard.artifact_url` | dashboard-artifactdata-allow | `""` (nothing auto-approved) |
| `repos[].app`, `repos[].services`, `repos[].infra`, `repos[].sut_namespaces` | post-deploy-retest | `[]` (fire on every cluster write) |
| `dark_factory.stage_gate` | install.sh (registers the two `df-*` hooks) | `false` |
| `guard.blocked_hosts` | pair-guard | `[]` |
| `guard.credential_dirs` | pair-guard, handoff | `.config/argus` always included; add your MCP hub's credential folders (an org pack can add its own, e.g. `.trilix`, `.onedroid-home`) |
| `guard.protected_namespaces` | deploy-gate, chat-approval | `kube-system`, `kube-public`, `kube-node-lease` (+ `default` for chat) |
| `guard.safe_script_subs` | deploy-gate | `{}` — e.g. `{checker.sh: [status, run, validate]}` |
| `guard.secret_paths` | secret-readback-guard | `[]` (regex fragments) |
| `argus.repos` | pair-guard | `[]` — checker repos the builder may not clone |
| `teams.mcp_server`, `teams.hub_workspace_id`, `slack.mcp_server`, `paths.mcp_json` | chat-approval | `.mcp.json` in `paths.shared_root` |

Test hooks: `PAIR_CONFIG=<a pair.yaml under /tmp>` plus `PAIR_GUARD_TEST_HOST` (pair-guard) or
`PAIR_LEDGER_DIR`/`PAIR_LEDGER_TEST_ROLE` (ledger) — honoured only for paths under `/tmp`.

## Agents (`agents/`, installed into `~/.claude/agents/`)

| File | Installed as | What it does |
|---|---|---|
| `adversary.md` | `<rules.reviewer>.md` (default `adversary.md`) | Independent reviewer: takes ONE claim + raw evidence, attacks it (re-run, scope, same-object, control, absence, counting, holdout, side effects) and returns GO / NO-GO / UNVERIFIED. Read-only tools; never reads the tester's tests. |
| `patrol.md` | `patrol.md` | Read-only patrol: reachability with a negative control, health, the tester's run status, rollout drift, open PRs / Dependabot; drafts a post starting with the bot marker for the builder to send. |

`{{reviewer}}`, `{{builder}}`, `{{tester}}`, `{{owner}}`, `{{project}}` are filled from pair.yaml at install; a
differing existing file is backed up first.

## Read-only cluster identity

`k8s/agent-readonly.yaml` (ServiceAccount + get/list/watch ClusterRole without secrets, exec or port-forward) and
`kit/scripts/make-agent-kubeconfig.sh`, which only PRINTS the commands for the owner to run. When
`~/.kube/agent-readonly.conf` exists, `install.sh` sets `env.KUBECONFIG` in `~/.claude/settings.json` so the agents'
kubectl is read-only; when it is absent it warns loudly (the deploy gate alone is a tripwire, not a boundary).
