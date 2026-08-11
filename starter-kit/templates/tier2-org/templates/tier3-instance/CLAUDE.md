# Claude Instructions — __INSTANCE_NAME__

Context for agents working **in this instance repo**. Shared doctrine is injected at
session start by the Tier 2 hooks — this file covers only what is specific to me.

## What this repo is

My Tier 3 instance: personal skills, personal hooks, and the pin that selects which version
of the shared __ORG_DISPLAY__ environment (Tier 2) I run. It is not a service and ships no
application code.

Tier 2 owns everything shared. If a change here would benefit the whole org, it belongs in a
PR to `__ORG_REPO__` instead.

## Conventions

- **`instance.lock.json` is the authority**, `install.sh` is only the mechanism. A skill
  that exists on disk but is not registered will not be installed, and nothing will point
  at the omission.
- **Never edit `vendor/`** — a rebuildable cache of Tier 2, overwritten on every install.
  To take a Tier 2 update, change the `ref` in the lockfile.
- **Skills symlink, hooks copy.** Skill edits are live immediately; hook edits need a
  reinstall and a new session.
- **No secrets, ever.** Anything needing a key ships a `*.example` template only.

## Before the first tool call of a session

**Confirm the MCP tool namespace in this session.** There is no single prefix — the name
depends on how each machine connects, and two machines in the same org can legitimately
differ. If nothing resolves or it is ambiguous, **ask** — a wrong prefix is
indistinguishable from a missing tool, and an agent that wrongly concludes a system is
unavailable may invent state rather than report the gap.

## Personal notes

<!-- Anything an agent should know about how you work that is not shared doctrine.
     Keep it terse — this is read every session, so every line costs attention forever. -->
