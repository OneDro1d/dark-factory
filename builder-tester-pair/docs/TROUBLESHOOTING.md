# Troubleshooting

Every one of these happened during the first real setup; the fixes are already built in where they can be.

| Symptom | Cause | Fix |
|---|---|---|
| Every tick says "skipped … no tokens left" | That Claude process used up its session allowance; `/clear` does not reset it | A restart is a fresh process (`tmux respawn-pane -k`); the watchdog does this. Send `<name> restart` |
| A fresh agent sits silent after a restart | A question or survey on its screen | `tmux attach -t <name>`, answer it, Ctrl-b d |
| Agent hangs at its first action | Started without `--permission-mode auto` | Always start with `kit/scripts/start-agent.sh` |
| "401 missing_token" for an MCP connector | That workspace never signed in to it | Sign in there (your hub client's own sign-in, e.g. `<client> login --device`), then restart the agent |
| An MCP connector's tools are missing entirely | Agent started outside the shared folder, so the project `.mcp.json` didn't load | Start scripts pin the folder; restart with `start-agent.sh` |
| Several restart messages, several restarts | (fixed) | A message sent before the last restart finished is a repeat and ignored |
| A listener rule seems to be ignored | Its key isn't in the channel-listener skill's key list | Add the key to `skills/channel-listener/SKILL.md` |
| Teams post rejected as "not HTML" | Message sent in `content` | Use the `body` field with `is_html: true` |
| Slack paused as "identity unclear" | Profile read in the concise format (no user id) | Read it with `response_format: detailed` |
| `handoff` says "neither builder.host nor tester.host" | Hostname in pair.yaml doesn't match `hostname` | Fix `builder.host` / `tester.host` |
| A guard block from your own test | Test text contained a test-kit path | Build paths from pieces in tests; the block is logged and reported, that's expected |
| The watchdog didn't pick up a script change | It runs the copy it started with | `tmux kill-session -t watchdog`, then `start-agent.sh` |
