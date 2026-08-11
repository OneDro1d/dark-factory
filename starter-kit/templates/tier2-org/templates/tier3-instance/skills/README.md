# Your skills

One directory per skill, each containing a `SKILL.md` with frontmatter:

```markdown
---
name: my-skill
description: What it does and when to use it. This text is how the agent decides to
  invoke it, so write it as trigger conditions, not as a title.
---

The instructions.
```

Then register it in `../instance.lock.json` and run `../install.sh`:

```json
"skills": { "my-skill": "skills/my-skill" }
```

**A skill on disk but absent from the lockfile is installed by nothing and reported by
nothing** — it survives until the next wipe, then silently is not there.

Skills are **symlinked**, so editing here updates the live skill immediately. No reinstall
needed for content changes — only for adding or removing one.

Naming a skill the same as a Tier 2 skill overrides it. That is supported and reported.
