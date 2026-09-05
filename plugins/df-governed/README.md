# df-governed

`df-governed` is the runtime half of the dark-factory three-tier method. Tier 1 (this repo) is
the generic method; the plugin is the mechanism that makes an installed instance of that method
**active** rather than merely declared — a hook that ships in `hooks/hooks.json` fires with no
separate wiring step, a skill in `skills/` namespaces itself, an executable in `bin/` joins the
Bash tool's `PATH` while the plugin is enabled, an entry in `monitors/monitors.json` starts
itself, and an agent in `agents/` is available to any launcher by name. None of that requires an
installer to hand-copy files and then have a separate check confirm the copy was wired correctly.

## The seam: plugin is runtime, the lockfile is the pin

```
WHAT the agent is       →  this plugin: skills, hooks, agents, bin/, monitors
WHICH machine this is   →  a Tier-3 lockfile: identity, codeRoot, codeLayout, probed paths,
                            notRestorable — none of which may ever appear in this directory
```

The plugin is public and generic. A Tier-3 instance pins it by `sha` and supplies everything
that is true only of one machine or one person. The plugin never carries that half, and the
Tier-3 lockfile never carries the plugin's content — each side owns exactly one kind of fact.

## The seven objectives this plugin will carry

1. Autonomy — via vinculum-loop, Promise Theory, the data-transform lens, delegation, and model
   tiering, enforced rather than merely instructed.
2. Headless workflows — subagents and subworkflows run through one launcher contract, keeping
   the supervising session's chat clean.
3. Compaction and `/clear` survival — via one precise, gated handoff.
4. The agent answers its own questions first, on the most capable model available to it.
5. A recurring tick reminds the agent an open mission is still unfinished.
6. Progress is tracked in a persistent layer — a map and tickets, not just commit history.
7. Which notepad a session is scoped to is disclosed, not left for the reader to infer.

## `agents/`

`agents/` deliberately has no README: the plugin validator reads every `.md` in that
directory as an agent definition and warns on a file without frontmatter, and a warning that
ships is a warning people learn to ignore. What the directory is for:

It holds `df-orchestrator`, the agent a launcher opts into by name (`--agent df-orchestrator`);
see the next section for why it is not activated for every session by default. Per the plugin
docs, plugin-shipped agents cannot carry
`hooks`, `mcpServers`, or `permissionMode` frontmatter ("For security reasons, `hooks`,
`mcpServers`, and `permissionMode` are not supported for plugin-shipped agents") — an agent that
needs any of those three lives outside this plugin, beside it in a project's `.claude/agents/`,
never here.

## Why `settings.agent` is NOT set

`agents/df-orchestrator.md` ships, but `settings.json` is `{}` and `plugin.json` declares no
`settings`. The design asked for `{"agent": "df-orchestrator"}` so the orchestrator's model would
arrive with the pin. Measured against the docs before shipping (code.claude.com/docs/en/sub-agents):
"The subagent's system prompt replaces the default Claude Code system prompt entirely, the same way
`--system-prompt` does." Activating `agent` here would therefore make every session on every machine
with this plugin enabled run on an eight-line doctrine as its ENTIRE system prompt. That is a
regression wearing a mechanism.

What ships instead: the agent definition, with `model: inherit`, for a launcher that opts in
explicitly (`claude --agent df-orchestrator`, or a supervisor profile that passes `--model` per
role). The tier is then a launch-profile decision — visible, per role, reversible — and no model
name is frozen into a public file, where it would age into a silent downgrade.

## claim-gate: which tool call counts as the claim

`hooks/claim-gate.py` decides which tool call is the mechanical claim on a tracker item, and
that decision is tracker-shaped, not hardcoded to one tracker. Three env vars, exported by
`df-worker`'s matching `--claim-tool` / `--claim-item-keys` / `--claim-values-key` flags,
tell it: `DF_CLAIM_TOOL` (a regex over `tool_name`), `DF_CLAIM_ITEM_KEYS` (comma-separated
`tool_input` keys that may hold the item id), and `DF_CLAIM_VALUES_KEY` (the `tool_input`
key holding the values `DF_CLAIM_COLUMNS` is checked against — the empty string means check
`tool_input` itself). Each defaults to the original Monday-only shape
(`itemId`/`item_id`/`itemID`, values under `columnValues`), so a worker launched without
these flags is unaffected. A Monday tracker needs none of them; a Notion tracker (item id in
`page_id`, claim fields nested under a `properties` object) sets all three; a Jira tracker
(item id in `issue_key`, claim fields like `assignee` at the top level of `tool_input`, with
no nested values object) sets `DF_CLAIM_VALUES_KEY` to the empty string.

## Developing this plugin

Load it directly from a working tree, without installing it:

```bash
claude --plugin-dir plugins/df-governed
```

## Hard rule

Nothing under this directory may name a specific host, person, client, token, or machine path.
This tree is Tier 1: public, generic, and pinned by `sha` from private Tier-2 and Tier-3 layers
that carry those specifics instead. `boot-kit/scripts/publish-gate.sh` enforces this at publish
time; a violation here is a hard stop, not a style note.
