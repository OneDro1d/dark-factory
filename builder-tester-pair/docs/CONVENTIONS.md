# Conventions for this kit

1. **Nothing project- or person-specific in code.** Every name, id, path, repo, channel, label and schedule comes from
   `pair.yaml` through `kit/lib/pairconf.py` (`pairconf.load()`, `get(cfg, "dotted.key")`, `role()`, `name()`,
   `ledger_dir()`, `apps()`). Shell scripts call `python3 kit/lib/pairconf.py get <key>` / `role`.
2. **Role ids are `builder` and `tester`** (and `owner` for the human). Display names come from `builder.name`,
   `tester.name`, `owner.name`. Messages use the configured names or the words "the builder" / "the tester" /
   "the owner".
3. **The role is decided by hostname** (`builder.host` / `tester.host`), never by an environment variable an agent
   could set. An unlisted machine may only read.
4. **Optional integrations are optional.** Teams, Slack, Jira, Engram and Argus are each skipped cleanly when their
   section of `pair.yaml` is empty.
5. **Generated files are rendered, not edited.** Listener configs, start commands and the watchdog's agent list are
   produced by `./setup-pair render` from `templates/` + `pair.yaml`. Placeholders are `${dotted.key}` (string
   values) — see `setup-pair`.
6. **Every NEW or CHANGED tool gets a `--selftest`** (or a test next to it) that runs with a throw-away `pair.yaml`
   under `/tmp` (`PAIR_CONFIG=...`), and passes before it is committed. Not there yet — these have no self-test:
   `kit/bin/{handoff,board,canary,canarylib.py,dashboard-live-snapshot,restart-request}`,
   `kit/hooks/{df-stage-gate.py,df-dispatch-subagents-reminder.py,session-start.sh}`,
   `kit/scripts/{start-agent.sh,agent-watchdog.sh,argus.sh,hub-login.sh,make-agent-kubeconfig.sh,parity-check.py,restore-home.sh}`,
   `setup`, `setup-pair`, `install.sh`, and an optional org pack's shell hooks plus `context-budget.py`, `df-preflight-guard.py`
   and its copies of `df-stage-gate.py` / `df-dispatch-subagents-reminder.py`. (`kit/hooks/ledger_common.py` is a
   library, tested through `action-ledger.py --selftest`.)
   Remove a name from this list in the commit that adds its test.
7. **No secrets in the repo.** Tokens are created by sign-in steps on each workspace and stay in that home folder.
   Presence checks use sizes or counts, never values.
8. **Test grep before commit:** `grep -rniE "<your org, project, people and agent names>"` over `kit/`,
   `templates/`, `skills/` must find nothing except the credits line in the README.

Engram is the memory store named here. What it is and how to reach it is documented in exactly one place: [Engram](../../starter-kit/instance/AUTHENTICATION.md#engram)
