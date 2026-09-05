# df-governed

`df-governed` is the runtime half of the dark-factory three-tier method. Tier 1 (this repo) is
the generic method; the plugin is the mechanism that makes an installed instance of that method
**active** rather than merely declared — a hook that ships in `hooks/hooks.json` fires with no
separate wiring step, a skill in `skills/` namespaces itself, an executable in `bin/` joins the
Bash tool's `PATH` while the plugin is enabled, an entry in `monitors/monitors.json` starts
itself, and `settings.json` can set the main-thread agent. None of that requires an installer to
hand-copy files and then have a separate check confirm the copy was wired correctly.

## The seam: plugin is runtime, the lockfile is the pin

```
WHAT the agent is       →  this plugin: skills, hooks, agents, bin/, monitors, settings.agent
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

It will hold the orchestrator agent that the main thread starts as once a Tier-3
lockfile pins a `sha` for this plugin — the agent's `model` (and its system prompt and tool
restrictions) arrive with that pin rather than being told to the session, and it is activated by
the `agent` key in `../settings.json`. Per the plugin docs, plugin-shipped agents cannot carry
`hooks`, `mcpServers`, or `permissionMode` frontmatter ("For security reasons, `hooks`,
`mcpServers`, and `permissionMode` are not supported for plugin-shipped agents") — an agent that
needs any of those three lives outside this plugin, beside it in a project's `.claude/agents/`,
never here.

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
