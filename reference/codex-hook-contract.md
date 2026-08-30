# The Codex CLI hook contract — measured, not read

**Measured 2026-08-31 against `codex-cli 0.139.0`** (npm, darwin-arm64), by extracting the
JSON schema and enum constants the shipped binary compiles in. Re-run the commands at the
bottom against a newer build before trusting any of it: this is a fact about **one version**,
not a promise about the product.

## Why this file exists

The estate's second-harness design assumed hook **scripts** are portable between Claude Code
and Codex, with only the *wiring* differing. That assumption had been carried for days with
an explicit caveat attached — *"an inference from documentation, not a measurement"* — and a
standing rule that no "works on Codex" claim ships without running one.

This is the measurement. **The headline is that the assumption holds**, and the two places it
does not are specific and small enough to render around.

---

## 1. The stdin contract is IDENTICAL

Codex sends a hook the same field names Claude Code does, in the same snake_case:

```
session_id   transcript_path   cwd   hook_event_name
tool_name    tool_input        prompt   source   permission_mode
```

## 2. The stdout contract is IDENTICAL

Same envelope, same camelCase — including the inner `hookEventName`, which is the one field
whose casing differs from its stdin twin in *both* harnesses:

```
hookSpecificOutput { hookEventName, additionalContext, … }
systemMessage   continue   suppressOutput   permissionDecision   stopReason
```

**Consequence: a hook script that reads stdin and prints the Claude Code envelope needs no
change.** That is the claim the caveat was blocking, and it is now measured.

## 3. ⚠️ The WIRING keys differ — snake_case, in a different file

Claude Code wires hooks in `settings.json` under **PascalCase** event keys. Codex wires them
in **`hooks.json`** under **snake_case** keys:

```
pre_tool_use   permission_request   post_tool_use   pre_compact   post_compact
session_start  user_prompt_submit   subagent_start  subagent_stop
```

This is the renderer's whole job for hooks: same scripts, same I/O, different filename and a
case transform on the event key. It is mechanical, which is the point of having measured it.

## 4. ⚠️ Not every event can INJECT — only six carry a structured output wire

All ten event names below exist as `hook_event_name` constants, but only six define a
`…HookSpecificOutputWire`:

| event | exists | structured output |
|---|---|---|
| `SessionStart` | ✅ | ✅ |
| `UserPromptSubmit` | ✅ | ✅ |
| `PreToolUse` | ✅ | ✅ |
| `PostToolUse` | ✅ | ✅ |
| `PermissionRequest` | ✅ | ✅ |
| `SubagentStart` | ✅ | ✅ |
| `PreCompact` | ✅ | ❌ observe / block only |
| `PostCompact` | ✅ | ❌ |
| `Stop` | ✅ | ❌ |
| `SubagentStop` | ✅ | ❌ |

A hook on one of the bottom four can still run and still fail the turn; what it cannot do is
hand structured context back. Wiring an injecting hook to `Stop` under Codex would run it and
silently discard its output — a "rendered the wiring, nothing happened" failure of exactly
the kind `lock-verify` L9 exists to catch one tier down.

## 5. ⚠️ `SessionEnd` DOES NOT EXIST in this build

Zero occurrences in the binary. A previously circulated list of Codex's events included it;
that list was otherwise accurate and wrong on this one item. Do not render a `SessionEnd`
hook for Codex — there is nothing to render it to.

## 6. ⚠️ Hooks must be TRUSTED, not merely wired — no Claude Code analogue

`codex --dangerously-bypass-hook-trust` exists precisely because the default is to refuse an
untrusted hook, and the binary carries a persisted `hook_trust` record plus a TUI flow for
granting it. **A correctly rendered `hooks.json` on a fresh machine still runs nothing until
trust is granted.** An installer that renders the file and reports success has not finished
the job, and nothing in the Claude Code path teaches you to expect that step.

## 7. Blocking works, and says so

`Command blocked by PreToolUse hook:` and `Tool call blocked by PreToolUse hook:` are both
compiled in, so the deny path is real rather than advisory.

---

## ⚠️ WHAT THIS DOES **NOT** PROVE

Stated plainly, because the whole reason this file exists is that an inference got mistaken
for a measurement once already:

- It proves the **schema the binary compiles in**. It does **not** prove a live session
  invokes hooks with that payload, honours the output, or applies the timeout the same way.
  A running-session probe is still owed.
- It says nothing about **which** of our scripts behave identically — only that the envelope
  they speak is the same one.
- It is **version-pinned to 0.139.0**. `0.151.0` was already available when this was written.

## Reproducing it

⚠️ **`command -v codex` is the WRONG starting point on an npm install, and the first draft of
this recipe used it.** `/opt/homebrew/bin/codex` is a `#!/usr/bin/env node` shim — `strings`
on it returns nothing, so the recipe printed empty output and would have read as "the schema
is gone" on the next version. Find the platform binary instead:

```bash
# The real Rust binary, wherever the platform package put it. `codex doctor` also prints it
# as `executable`, which is the check if this find comes back empty.
BIN="$(find "$(npm root -g)/@openai/codex" -type f -name codex -perm -u+x 2>/dev/null | head -1)"
[ -n "$BIN" ] || { echo "resolve it from: codex doctor | grep executable"; exit 1; }

strings "$BIN" | grep -oE '[A-Za-z]+HookSpecificOutputWire' | sort -u
strings "$BIN" | grep -oE '"const": "(PreToolUse|PostToolUse|SessionStart|SessionEnd|UserPromptSubmit|Stop|SubagentStop|SubagentStart|PreCompact|PostCompact|PermissionRequest)"' | sort -u
strings "$BIN" | grep -oE '"(session_id|transcript_path|cwd|hook_event_name|tool_name|tool_input|prompt|source|permission_mode)"' | sort -u
strings "$BIN" | grep -oE '"(hookSpecificOutput|hookEventName|additionalContext|systemMessage|continue|suppressOutput|permissionDecision|stopReason)"' | sort -u
strings "$BIN" | grep -oE 'pre_tool_use[a-z_]{0,140}' | sort -u
```

⚠️ One trap met while doing this: `codex --strict-config` **did not reject a deliberately
invented config key** under `doctor`, so "the config was accepted" is not evidence that a key
is real. The nonsense-key control is what revealed that, and it is why the findings above come
from the compiled schema rather than from what the CLI tolerated.
