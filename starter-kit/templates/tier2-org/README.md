# __ORG_LAYER_NAME__

The shared __ORG_DISPLAY__ agent environment — **Tier 2** of a three-tier setup.

```
OneDro1d/dark-factory          Tier 1 — the generic Dark Factory method. Public.
        │                              You never clone it directly; install.sh
        ▼                              fetches it at the pinned commit.
__ORG_REPO__  (this repo)      Tier 2 — what everyone in __ORG_DISPLAY__ shares:
        │                              curated upstream skills + org skills,
        ▼                              hooks, doctrine. THIS is the repo you clone.
<your instance>                Tier 3 — yours alone. Generated in one command,
                                       holds only your personal additions.
```

**Why three tiers:** your personal setup and the shared layer stay in separate repos, so
you take shared updates forever without a single merge conflict. Your instance pins this
repo by commit SHA and takes an update by changing one line.

## Quick start

```sh
# 1. the shared environment
git clone https://github.com/__ORG_REPO__.git
cd __ORG_LAYER_NAME__
bash install.sh

# 2. your own instance
bash scripts/new-instance.sh my-agent ~/Code
cd ~/Code/my-agent
bash install.sh
```

Prerequisites: `git`, `jq`, an agent harness (e.g. Claude Code), and read access to this
repo. Then: let your agent choose its own name, confirm your MCP tool names, wire the
hooks, and **start a new session**.

## Three things that will eat your afternoon if you skip them

1. **Confirm your MCP tool namespace.** There is no single prefix — it depends on how each
   machine connects. A wrong prefix looks exactly like a missing tool, and an agent that
   decides a system is unavailable may invent state rather than tell you.
2. **Restart after installing.** Hooks and MCP manifests are read once, at session start.
3. **Skills are symlinked, hooks are copied.** Editing a skill is live immediately.
   Editing a hook does nothing until you re-run `install.sh`.

## What belongs in this repo

- `org.lock.json` — **the authority.** Which Tier 1 commit, which skills, which hooks.
- `skills/` — skills written by and for this org (referenced as `local:skills/<name>`).
- `hooks/` — org hooks (`local:hooks/<name>`); use `__HOME__` for home paths.
- `scripts/new-instance.sh` — generates a developer's Tier 3 instance, pinning this repo
  by commit SHA at generation time.
- `templates/tier3-instance/` — what that generator stamps out.

What does NOT belong here: personal doctrine (Tier 3), the generic method (Tier 1 — send
upstream PRs instead), secrets (nowhere in git, ever).

## Declaring a skill or a hook

`org.lock.json` says it twice, on purpose:

```json
"install": {
  "skills": ["vinculum-loop", "our-own-skill"],
  "skillSources": {
    "vinculum-loop":  "upstream:dark-factory/skills/vinculum-loop",
    "our-own-skill":  "local:skills/our-own-skill"
  }
}
```

The **array** is the declaration; the **`*Sources` map** says where each one comes from.
A source is resolved under `vendor/` unless it starts with `local:`, which resolves inside
*this* repo — and against this **lockfile's** directory, not the installer's own location,
so it still means this repo when the installer is a vendored copy. `upstream:` is the
explicit spelling of the default; a bare path means the same thing. A value containing
`..` is refused, never normalised.

Both halves are required. A name with no source, and a source with no name, each install
nothing while still reading like a declaration — `install.sh` reports either, and
`lock-verify` L7 fails on either.

### If your layer predates this shape

Older layers wrote `install.skills` as a single map of name → source. The installer
**refuses** that shape rather than reading it — an installer that understands both forever
is how a third reading appears. `lock-verify` L7 refuses it too, and names this same
command: a verifier more permissive than the installer is how "in sync" comes to mean two
different things in one estate. Convert once, then carry on:

```sh
python3 vendor/dark-factory/boot-kit/scripts/df-lock-migrate.py --lock org.lock.json          # inspect
python3 vendor/dark-factory/boot-kit/scripts/df-lock-migrate.py --lock org.lock.json --apply  # write
```

The same applies to a developer's `instance.lock.json`.

## Taking a Tier 1 update

```sh
git ls-remote https://github.com/OneDro1d/dark-factory.git refs/heads/main
# edit upstreams["dark-factory"].commit in org.lock.json to the new SHA
bash install.sh
```

Pin the commit, never the branch — a branch can move under you between installs, and it
moves most while under review, exactly when people are onboarding onto it.
