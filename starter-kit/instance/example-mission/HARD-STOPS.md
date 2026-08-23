- **Every write goes inside this mission directory.** `RESULT.md`, `TICKETS.md`, `state`,
  and a `handoffs/` you create here. Nothing above it, ever — not the notepad root, not
  `MAP.md`, not the instance's `handoffs/`, not the lockfile, not `~/.claude`. The standing
  iteration template names some of those; this list outranks it.
- **Read-only outside this directory.** Inspecting the installed engine, the lockfile and
  the harness config is the point of the mission. Changing any of them is not.
- **No git operations of any kind.** No `add`, `commit`, `branch`, `tag`, `push`, `pull`,
  `checkout`, `stash` or `clean`. This mission produces a file; whether it belongs in your
  history is a decision for you, in a session you are watching.
- **No network.** No hub call, no tracker write, no fetch, no `git ls-remote`, no package
  install. The mission is defined so it does not need one — a step that seems to need the
  network is a finding to record, not an obstacle to route around.
- **No installs, no upgrades, no repairs.** If the run shows the runtime is broken on this
  machine, `RESULT.md` says exactly how. Fixing it is a separate mission you frame while
  watching.
- **Do not delete anything.** Not a stale file, not an empty directory, not a `__pycache__`.
  A cleanup that was obviously safe is how an unattended loop removes the one file someone
  needed.
- **No outbound message to a human.** No mail, no chat, no notification. The supervisor's
  own notify step is the only thing that speaks outward, and it runs after the loop exits.
- If something appears to require an action this list forbids, that is not a reason to
  reinterpret the list. Write `BLOCKED` to `state`, name the one specific thing you needed,
  and stop — a blocked example mission is a **successful** example mission if the reason is
  recorded well.
