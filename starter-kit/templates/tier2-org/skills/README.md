# Org skills

Skills written by and for __ORG_DISPLAY__ — one directory per skill, each with a
`SKILL.md` (frontmatter: `name`, `description`; the description is what triggers the
skill, so write it as trigger conditions).

Register each in `../org.lock.json` — the name in the `install.skills` array, and
`"<name>": "local:skills/<name>"` in `install.skillSources` — then re-run
`../install.sh`. **A skill on disk but absent from the lockfile is installed by nothing
and reported by nothing.**

A local skill with the same name as an upstream one overrides it — supported, and
reported loudly by the installer.
