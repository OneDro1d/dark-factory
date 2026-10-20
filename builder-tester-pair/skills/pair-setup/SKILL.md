---
name: pair-setup
description: Set up a builder/tester agent pair for any project — asks the questions, looks up Teams/Slack/Jira ids for the person, connects the repos, creates the memory (Engram) spaces, writes pair.yaml, renders both workspaces' files and lists the sign-in steps only a person can do. Use when someone says "set up a builder and tester", "/pair-setup", or wants to add a new project/pair.
---

# /pair-setup — set up a builder/tester pair

You are setting up two agents for ONE project: a **builder** (writes code to a spec, never sees the tests) and a
**tester** (product owner + architect + tester: agrees the requirement, writes the acceptance criteria and design,
writes hidden tests, judges results). The person running this is the **owner**: they approve deploys and merges.
Everything about the pair lives in one file, `pair.yaml`; the kit is this repo (`builder-tester-agents`).

## How to run it — ONE question at a time, from the kit's own question list

The questions live in `kit/lib/questions.yaml` and are the same ones `./setup` asks in a terminal. Drive them
with the kit, never from memory. **If you can pick a value automatically, pick it — don't ask; show everything you
gathered at the end, once, to confirm.**

1. `./setup-pair ask --auto` → fills every answer that needs no person and prints "Filled N automatically …; M still
   need an answer": values it measured (hostname, workspace, shared folder, git identity, active gh account),
   values derived from other answers (slug, start commands, labels, memory-space names, ledger paths), values
   already in pair.yaml or its pack (`extends`), and safe defaults (yes/no and list defaults, `auto: true` ones).
   A section is opened automatically only when the file or the pack already uses it. If it says "Answer `extends`
   first", ask that one question (step 3) and run `--auto` again — the pack changes the other defaults.
2. `./setup-pair ask --auto --next --json` → the next question nobody could decide (it re-runs the auto-fill first,
   so an answer you just recorded fills what is derived from it): `ask`, `default`, `choices`, `help`, `lookup`,
   `left`.
3. If `lookup` says how to find the value with your tools (Teams ids, Slack user id, Jira workspace…), LOOK IT UP
   and record what you found with `set` — do not ask. Otherwise ask exactly that ONE question with
   AskUserQuestion: the default as the first option marked "(Recommended)", the `choices` as options, "skip" where
   blank is allowed; the person can always type their own answer. For a section gate (`key` starts with `@use:`)
   offer Yes / No.
4. Record it: `./setup-pair set <key> "<value>"` (lists comma separated; repos / rules / channels / environments as
   JSON — `example` shows the shape; for those, ask one item and one field at a time, then set the whole list).
   A "No" to a section gate: `./setup-pair skip "<section>"`. `set` marks the answer's source "you" and re-derives
   any answer derived from it (e.g. memory-space names after the slug changes).
5. Repeat 2–4 until it says done. Everything is saved after each answer, so the person can stop and resume.
6. Confirm: run `./setup-pair ask --summary` (or `--json`) and show it — every answer, its value and its source
   (auto-detected / derived / existing / pack / default / you), by section, plus anything still pending. Ask ONE
   AskUserQuestion: "All correct" (Recommended) / "Change …" (the person names the key and the new value). For a
   change: `./setup-pair set <key> "<value>"`, show the summary again, and ask again until "All correct".

Then run the steps in section 8 ("Steps"), one at a time, telling the person what each does and asking before
each. Never ask for, read or print a password or token: sign-ins are steps the person does themselves.

The sections below say how to LOOK UP each kind of value; the order of questions comes from `ask --next`.

## 1. Where the pair lives
- Shared folder both workspaces mount (e.g. `/fleet/fleet/<project>`): ask. This repo should be cloned at
  `<shared_root>/builder-tester-agents`; if it is elsewhere, tell them to move it (or clone it there) — agents start
  in the shared root so its `pair.yaml`, `.mcp.json` and `CLAUDE.md` load.
- Project name and a short lowercase slug.

## 2. The people and the two agents
- Owner: name, email.
- Builder and tester **names** (any names; they become chat words: "<name> restart", "<name> — build …").
- Each agent's workspace name and hostname. If the person is in one of those workspaces now, run `hostname` for
  them. The tester's Kubernetes namespace if its workspace is a pod (`cat /var/run/secrets/kubernetes.io/serviceaccount/namespace`
  inside it); blank otherwise.

## 3. Repos — connect as many as they need
For each app: a short app name, the GitHub repo (`owner/name`), the base branch PRs target, and optionally the
branch/commit that is deployed (for the knowledge base). Check access as you go: `gh api repos/<owner/name> --jq .full_name`.
No access → tell them which `gh` account is active (`gh auth status`) and stop for that repo; never switch accounts
yourself.

## 4. Chat and tickets (each optional — skip cleanly if they don't use it)
Use the MCP tools you have (list your tools first; names differ per install):
- **Teams**: list the hub's workspaces/accounts to get `teams.hub_workspace_id`; get the owner's user id from their
  profile; list teams → let them pick the team; list its channels → let them pick the change channel (every
  hand-over step and deploy is posted there) and any channels to watch.
- **Slack**: read the owner's own profile with `response_format: detailed` (the concise format shows no id) for
  `owner.slack_user_id`; read their DM history with their own user id to learn the self-DM channel id (`D…`);
  search channels to watch.
- **Jira**: confirm the project key exists; labels default to `agent-<builder>` and `agent-<tester>`.
- **Argus** (optional end-to-end checker): its URL and which apps have workspaces.

## 5. Memory (Engram)
Propose these namespaces (from the slug and names) and, when the person agrees, create each one with your Engram
tool (`engram_create_namespace` or the equivalent your install exposes):
`<slug>-<builder>-memory`, `<slug>-<builder>-behaviors`, `<slug>-<tester>-memory`, `<slug>-<tester>-behaviors`,
`<slug>-<builder>-sessions`, `<slug>-<tester>-sessions`, and the shared knowledge base `<slug>-knowledge`
(builder writes code-cited pages, tester reads them). If one exists already, reuse it. Report what you created.

## 5b. Optional settings — ask by group, accept "skip" for a whole group
Every key below is optional; say the default and write nothing when the person accepts it. Ask one group at a
time, only groups that apply (no Slack → skip the Slack group). Never ask for a secret.
- **Owner and team** — `owner.mention_names` (other display names that count as an @mention of the owner;
  default `[owner.name]`); `owner.slack_not_self` (look-alike Slack ids that are NOT the owner; `[]`);
  `team.decision_contact` (`{name, teams_user_id}` of who decides when the requester cannot — look the id up;
  `{}`).
- **Scope of what the agents pick up** — `project.topics` (in-scope topics beyond the apps, e.g. the programme
  or contract; `[]`); `scope.exclude` (look-alike orgs/products that are out of scope even when keywords match;
  `[]`); `listener.extra_keywords` (`[]`). Only if they ask: `listener.thread_window` 20,
  `listener.thread_max_age_days` 7, `listener.surge_threshold` 25, `listener.pending_max_items` 500,
  `listener.pending_max_age_days` 30.
- **Slack** — `slack.dm_search_tool` (default `slack_search_public_and_private`); `slack.retired_channels`
  (ids never read; `[]`); `slack.workspace_org` (set when the Slack workspace belongs to another org, so most
  traffic is out of scope; `""`).
- **Jira card rules** — `jira.mcp_server` (`""`); `jira.card_rules` (`required_labels`, `label_families`,
  `issue_type`, `require_parent`, `require_points`, `priority`; all empty/false by default);
  `jira.closed_statuses` (statuses an agent never moves a card to; `["Done"]`); `jira.scope_authority` (who owns
  deliverables/epics — never invented; `""`); `jira.audience` (who a card is written for; default "a reviewer
  who was in none of our conversations"); `jira.ignore_labels` (look-alike labels that are NOT assignments;
  `[]`).
- **Memory beyond the pair's own spaces** — `engram.org_rules` (read-only org operating-rules namespace,
  searched before any Jira/Confluence/change post; `""`); `engram.team` (team-wide knowledge space where
  team-wide lessons go; `""`). Check each exists with your Engram tool; never create an org's space.
- **Rules** — `rules.standing` (the owner's standing rules, verbatim, as `{rule, why, by, date}`; loaded at
  every start by both agents; `[]`) — ask "any rule the agents must always follow?" and write their words, not a
  summary; `rules.never_post` (channels the agents read but never post to, e.g. `[slack]`; `[]`);
  `rules.shared_writes` (what counts as a shared-data write that needs the owner's OK; `""`);
  `rules.review_sample` (1 in N routine verdicts the reviewer re-checks; `5`); `rules.result_parsers` (tools
  that count test results — never a summary line; `[]`); `rules.deploy_rulebook` (path; `""`).
- **Environments and images** — `environments` (`[{name, cluster, branches, team_requests: allowed|owner_only}]`;
  `[]`); `registry` (`{push_host, pull_host, project}`; `{}`).
- **Dark Factory** — `dark_factory.enabled` (default `false`). If yes: `dark_factory.loop_skill`
  (`dark-factory-build`), `dark_factory.skills_dir` (`""`), `dark_factory.stage_gate` (`false`), and
  `dark_factory.skills` — show the default stage→skill map (product_owner df-product-owner, architect
  df-solution-architect, build df-tdd-developer, adversary df-adversary-gate, qa df-qa, reading
  requirements-discovery, coverage [test-strategy, dependency-mapping], contracts contract-check, data_pipeline
  df-data-transform-lens, ui df-ui-verify, outcomes df-observability, auth security-threat-modeler, test_quality
  [critical-thinking]) and change only the stages they name. Check each named skill is installed
  (`ls ~/.claude/skills`); a missing one → tell them, leave the stage empty.
- **Tester inputs** — `knowledge.requirements_index` (title of the node every requirement node is linked from;
  `""`); `paths.findings_file` (past findings; non-security items become regression checks; `""`); per repo
  `repos[].sut_namespaces` (namespaces the app's services run in; `[]`) and `repos[].input_schemas` (globs of
  the files that define the app's inputs — hostile inputs are generated from these; `[]`);
  `tester.private_dir` (the tester's private folder the builder and hand-overs never touch; `""`).
- **Argus** (only when `argus.url` is set) — `argus.existing_suites` (`[{app, owner}]` suites someone else owns,
  reused once that owner OKs it, never duplicated; `[]`).

## 6. Write pair.yaml and render
- Start from `pair.example.yaml`; fill every answer in; write it to `<shared_root>/pair.yaml` (back up any existing
  one first). Show the person the final file.
- In THIS workspace run `./install.sh` (it links skills, installs and registers hooks, renders this workspace's
  listener config and start command, and runs `./setup-pair check`).
- Knowledge base (skip if they do not want one: leave `engram.knowledge` empty). Ask in plain words, then fill
  the `knowledge:` section:
  1. "Which branch should it learn from — what is deployed, the PR base, or one branch such as main?" →
     `knowledge.branch` (`deployed` | `base` | name; per repo if they differ).
  2. "How should the code be split up for research?" Offer the default (one area per app plus `cross`); otherwise
     write `areas: [{name, apps, focus}]`.
  3. "Any other branch running in production we must track too?" → `knowledge.lines`.
  4. Only if they ask: extra page kinds, graph relations, or switching off a growth trigger (`grow_on`).
  Then run `./setup-pair knowledge init` in the builder workspace and show its output. Tell them the first build is
  `/knowledge-build` in the builder's Claude session, and it grows by itself after that.
- The other workspace: they run `./install.sh` there (same shared folder, so it finds the same pair.yaml).

## 6b. Your own dashboard — every person publishes their own private copy
The kit ships the page, not a URL: `templates/dashboard/control-room.html` (the live "Control Room": needs-you
board, hand-over loops, requirements, test runs, scorecard, PRs, alerts, health, approvals, reports, activity,
and a stale-tick warning after `schedule.stall_minutes`). It titles itself from the snapshot (project, owner,
builder and tester names), so it needs no editing. Ask "do you want a live dashboard?" — no → leave
`dashboard.artifact_url: ""` (empty = no dashboard; the builder skips the snapshot push) and move on.
If yes, in the **owner's own** Claude session (the person whose pair this is — never on their behalf from
someone else's account):
1. Load the `artifact-capabilities` skill first.
2. Publish `templates/dashboard/control-room.html` as a **NEW private artifact** with the Artifact tool — no `url`
   (never update an existing one), icon e.g. `dashboard`, and exactly the capabilities the page's header comment
   names: `capabilities: {"db": {"rules": [{"path": "", "write": "admin"}]}}` (everyone it is shared with may
   read; only the owner/editors write).
3. Write the returned `https://claude.ai/...artifact/...` URL into **their** pair.yaml `dashboard.artifact_url`,
   then re-run `./setup-pair render` in each workspace (and `./install.sh` in the builder workspace if the
   `dashboard-artifactdata-allow` hook is not registered yet).
4. `./setup-pair check` shows `dashboard: your own page <url>` (PASS) or `off`; a URL that is not a claude.ai
   link is flagged. The page shows "waiting for the builder's first update" until the builder's next tick writes
   the first `snapshots/<ts>` document.
Rules: the URL is **per person, not per team** — never copy another person's `artifact_url` (from a pack example,
a teammate's pair.yaml or a doc): the builder would push your pair's state into their page, and the allow hook
would auto-approve it. Never publish it public; the owner shares it if they choose.

## 7. Steps only the person can do — list them, don't do them
1. In the **builder** workspace: `coder logout --yes` (the builder must not reach the tester's workspace).
2. In **each** workspace: sign in to the MCP hub tools they use (e.g. `bash kit/scripts/hub-login.sh`
   for Jira), then restart that agent.
3. **Argus** (if used): author tokens in the tester workspace only; runner tokens in the builder workspace.
4. In **each** workspace: `bash <kit>/kit/scripts/start-agent.sh` (starts the watchdog and the agent). Detach with
   Ctrl-b then d. If the agent sits at a question on screen, answer it.
5. In Teams self-chat: `<tester-name> restart` → expect a "Started" report from each agent.

## 7b. Steps (same as `./setup --steps`) — ask before each, show the command, report its last lines
1. `bash install.sh [--pack <name>]` — hooks, agents, skills (the pack name comes from `extends:`).
2. `./setup-pair render` — this workspace's rules and its OWN start command (`builder.start_command` /
   `tester.start_command`): each workspace gets only its role's rules and command.
3. `./setup-pair repos --clone`, then `./setup-pair engram` (create the listed Engram spaces with your tools).
4. Builder workspace only: `./setup-pair knowledge init`. Then tell the OWNER that the deploy-approval tool in
   `kit/bin/` is theirs to add (agents are blocked from writing approval tools) — docs/SETUP.md "Deploy approvals".
5. Dashboard (if wanted): publish `templates/dashboard/control-room.html` as the person's OWN new private artifact,
   `./setup-pair set dashboard.artifact_url <url>`, render again.
6. `./setup-pair check` — fix every FAIL with the person.
7. The OTHER workspace: same kit in the same shared folder, `./setup --steps` there (or `/pair-setup` there — the
   questions are already answered, only the steps run).

## 8. Prove it
Ask them to send one small real request to the tester (`<tester-name> — <ticket>: <small change>`) and watch it go
spec → build → local test → "deploy or review first?" in Teams, with every step in the change channel.
Point them to `docs/SETUP.md` (the full guide) and `docs/TROUBLESHOOTING.md`.

Engram is the memory store named here. What it is and how to reach it is documented in exactly one place: [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
