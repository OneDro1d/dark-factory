Skills placed here follow the `<name>/SKILL.md` directory layout and are namespaced by the
plugin's `name` field, so a skill folder named `handoff/` is invoked as `/df-governed:handoff`
rather than a bare `/handoff` — the namespace prevents collision with any same-named skill loaded
from a standalone `.claude/skills/` directory or from another plugin, and it makes "which copy
answered?" unambiguous at the call site.
