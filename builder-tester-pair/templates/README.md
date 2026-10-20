# templates/ — rendered by `setup-pair render`

Every file here is rendered once per pair from `pair.yaml`; the results go to the pair's workspaces
(listener config, start command) and to `<derived.kit>/generated/` (shared files such as the help list).
Never hand-edit a rendered file — change `pair.yaml` or the template and render again.

| Template | Rendered to (on that role's workspace) |
|---|---|
| `builder/listener.json` | `~/.claude/channel-listener/config.json` on the builder workspace |
| `tester/listener.json` | `~/.claude/channel-listener/config.json` on the tester workspace |
| `builder/start.md` | `~/.claude/commands/<builder.start_command>.md` |
| `tester/start.md` | `~/.claude/commands/<tester.start_command>.md` |
| `chat-commands.html` | `<derived.kit>/generated/chat-commands.html` (read by both agents' `help_command`) |

## Placeholder syntax

| Form | Where | Replaced by |
|---|---|---|
| `${dotted.key}` | anywhere (inside JSON strings too) | the value at that key in pair.yaml, or a derived value. Strings as-is; numbers as digits. **In `.json` templates the value must be JSON-string-escaped** (quotes, backslashes, newlines) before it is inserted, because it lands inside a JSON string. Missing key → empty string (the rules say "skip if … is empty"). |
| `"${json:dotted.key}"` | `.json` templates only, as a whole JSON value **including the surrounding quotes** | `json.dumps(value)` — a list or object. Written quoted so the template is valid JSON before rendering. |

## Keys read from pair.yaml

`project.name` · `owner.name` `owner.email` `owner.teams_user_id` `owner.slack_user_id` ·
`builder.name` · `tester.name` · `schedule.tick_minutes` · `rules.max_rounds` ·
`teams.hub_workspace_id` `teams.team_id` `teams.change_channel_id` `teams.tenant_id` ·
`jira.project` `jira.builder_label` `jira.tester_label` `jira.hub_workspace_id` ·
`engram.knowledge` `engram.builder_memory` `engram.builder_behaviors` `engram.tester_memory` `engram.tester_behaviors` ·
`dashboard.artifact_url`.

Two keys are **not yet in `pair.example.yaml`** and should be added there (both optional, empty = skipped):
- `teams.tenant_id` — the organisation's Azure AD tenant; DMs are acted on only from users in it.
- `dashboard.artifact_url` — the builder's live dashboard page; empty skips `live_dashboard`.

## Derived keys (computed by `setup-pair render`)

| Key | Value |
|---|---|
| `derived.kit` | absolute path of the installed kit (e.g. `<paths.shared_root>/builder-tester-agents`) |
| `derived.bin` | `<derived.kit>/kit/bin` |
| `derived.ledger` | `paths.ledger` (absolute) |
| `derived.knowledge_dir` | `paths.knowledge_drafts` if set, else `<paths.shared_root>/knowledge` |
| `derived.knowledge_rule_builder` / `derived.knowledge_rule_tester` | each agent's knowledge instructions, generated from the `knowledge:` section (branch, kinds, relations, `grow_on` switches) — see `knowledge_rules()` in `setup-pair` |
| `derived.builder_lc` / `derived.tester_lc` | `builder.name` / `tester.name` lower-cased (the chat words: `<name> restart`, `help-<name>`) |
| `derived.apps` | `repos[].app` joined with `|` (e.g. `api|web`) |
| `derived.app_branches` | `repos` as `app -> base` joined with `, ` (e.g. `api -> main, web -> release/2.4`) |
| `derived.prefilter_builder` | regex string (JSON-escaped when inserted): `(?is)^(?!.{0,25}\b<tester_lc>s?\b).*?(?:^\W*<builder_lc>\b|\b<builder_lc>\s*[,:!]|@<builder_lc>\b|<alternation of every scope alias, repo, service and infra name, re.escape'd, longest first>|<jira.project>-\d+)` — the last part only when `jira.project` is set |
| `derived.prefilter_tester` | `(?i)\b<tester_lc>\b` |
| `json:derived.scope` | object, one entry per `repos[]` item: `{"<app>": {"aliases": [<app>, <repo name part of github>, ...repos[].aliases], "repos": [<repo name>], "services": repos[].services or [], "infra": repos[].infra or [], "tickets": "<jira.project>-\\d+" or ""}}` (`aliases`, `services`, `infra` are optional per-repo lists in pair.yaml) |
| `json:derived.sources_builder` / `json:derived.sources_tester` | the list below |

### What `derived.sources_<role>` must contain

Build the list in this order, skipping any entry whose ids are empty. Keys are the state-file names under
`~/.claude/channel-listener/state/`; keep them stable across renders (they hold the watermarks).

1. One per `teams.watch_channels[]` item:
   `{"key": "teams-<item.key>", "kind": "teams", "workspace_id": "<teams.hub_workspace_id>", "team_id": "<teams.team_id>", "channel_id": "<item.id>", "max_results": 3}`.
   Include the change channel too when it is not already listed (`key: "teams-change"`, `channel_id: teams.change_channel_id`).
2. One per `slack.watch_channels[]` item:
   `{"key": "slack-<item.key>", "kind": "slack", "channel": "<item.name>", "channel_id": "<item.id>", "limit": 5}`.
3. Owner's self-chat (always, when `teams.hub_workspace_id` is set):
   `{"key": "owner-inbox", "kind": "teams-chat", "command_inbox": true, "workspace_id": "<teams.hub_workspace_id>", "chat_id": "48:notes", "max_results": 5}`.
4. Owner's Teams DMs (always, same condition):
   `{"key": "owner-dms", "kind": "teams-dms", "workspace_id": "<teams.hub_workspace_id>", "chat_types": ["oneOnOne", "group"], "addressed_only": true, "max_chats": 25, "max_results": 5}`.
5. Owner's Slack DMs (when `owner.slack_user_id` is set):
   `{"key": "owner-slack-dms", "kind": "slack-dms", "addressed_only": true, "limit": 20}`.
6. Owner's Slack self-DM (when `owner.slack_self_dm` is set):
   `{"key": "slack-self-dm", "kind": "slack", "channel": "<owner.name>'s Slack self-DM", "channel_id": "<owner.slack_self_dm>", "limit": 10, "addressed_only": true}`.
7. Jira (when `jira.project` is set):
   `{"key": "jira-assigned", "kind": "jira", "jql": "project = <jira.project> AND labels = \"<jira.builder_label | jira.tester_label for the role>\" AND statusCategory != Done ORDER BY updated DESC", "limit": 20, "workspace_id": "<jira.hub_workspace_id>"}`.

Both roles get the same list except the Jira label (builder: `jira.builder_label`, tester: `jira.tester_label`).

After rendering on a fresh home, seed every source's watermark to NOW (`/channel-listener init`) so old
messages — including old self-chat notes — are never replayed as instructions.

Engram is the memory store named here. What it is and how to reach it is documented in exactly one place: [Engram](../../starter-kit/instance/AUTHENTICATION.md#engram)
