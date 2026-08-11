# __INSTANCE_NAME__

My Tier 3 instance of the __ORG_DISPLAY__ agent environment.

## What this is

```
OneDro1d/dark-factory                    Tier 1 — the generic method, public
        │                                        fetched by Tier 2
        ▼
__ORG_REPO__                             Tier 2 — the shared __ORG_DISPLAY__ environment
        │                                        pinned by instance.lock.json
        ▼
__INSTANCE_NAME__  (this repo)           Tier 3 — mine alone
                                                 my skills, my hooks, my doctrine
```

**This repo holds only what is mine.** It pins Tier 2 and delegates to its installer for
everything shared — it deliberately does not re-list Tier 2's skills, because a second copy
of that list drifts the moment either side changes.

## Install

```sh
bash install.sh --dry-run    # see the plan
bash install.sh              # do it
bash install.sh --offline    # reinstall from cache, no network
```

Then confirm your MCP namespace, register the hooks, and **start a new session** — hooks and
MCP manifests are read once, at session start.

## Adding something of your own

**Put each change in the lowest tier that can hold it.** Ask "would everyone in the org want
this?" — if yes it belongs in Tier 2 via a PR, not here. This repo is for what is genuinely
yours: personal doctrine, experiments, work in progress.

### A skill

1. Create `skills/<name>/SKILL.md` (frontmatter: `name`, `description` — the description is
   what triggers it, write it for the matcher, not the reader).
2. Register it: `"<name>": "skills/<name>"` under `install.skills` in `instance.lock.json`.
3. `bash install.sh` — skills symlink, so later edits are live immediately.

### A hook

1. Create `hooks/<name>` (use `__HOME__` for the home directory — the installer substitutes
   it per machine).
2. Register it under `install.hooks`, run `install.sh`, wire it in `~/.claude/settings.json`,
   and start a new session — hooks are copies, so every edit needs a reinstall.

## Taking a Tier 2 update

One line: change `ref` in `instance.lock.json` to the new commit SHA, then `bash install.sh`.
Resolve the SHA with `git ls-remote https://github.com/__ORG_REPO__.git refs/heads/main` —
pin the commit, not the branch.
