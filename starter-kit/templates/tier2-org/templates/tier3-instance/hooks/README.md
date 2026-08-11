# Your hooks

Shell or Python scripts that Claude Code runs at session boundaries. Register each in
`../instance.lock.json`:

```json
"hooks": { "my-hook.sh": "hooks/my-hook.sh" }
```

## Two things that catch people

**Hooks are COPIED, not symlinked.** Editing a file here does nothing until you re-run
`../install.sh`. Skills behave the opposite way. When a hook edit "has no effect", this is
almost always why.

**A hook only takes effect in a NEW session.** Hooks are read once at session start.

## Writing one

- Use `__HOME__` anywhere you need an absolute home path — the installer substitutes it per
  machine, which is why hooks cannot be symlinked.
- A `SessionStart` / `UserPromptSubmit` hook must print valid JSON on stdout. Test it before
  you install it:
  ```sh
  bash hooks/my-hook.sh | jq -e '.hookSpecificOutput.hookEventName'
  ```
- Keep injected text **terse**. It is prepended to every session or every prompt, so a line
  that does not change what the agent does costs attention forever.
- Never emit a secret. Hook output goes into the transcript.
