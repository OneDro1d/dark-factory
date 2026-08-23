# Org hooks

Scripts your agent harness runs at session boundaries, shared org-wide. Register each in
`../org.lock.json`: the file name in the `install.hooks` array, and
`"<name>": "local:hooks/<name>"` in `install.hookSources`. Both halves are required.

- **Hooks are COPIED, not symlinked** — an edit here does nothing until `install.sh`
  re-runs, and only takes effect in a NEW session.
- Use `__HOME__` for absolute home paths; the installer substitutes it per machine.
- Wire installed hooks into each machine's `~/.claude/settings.json` (merge into existing
  arrays — do not overwrite someone's settings).
- Keep injected text terse: a line that does not change what the agent does costs
  attention in every session forever. Never emit a secret — hook output lands in the
  transcript.
