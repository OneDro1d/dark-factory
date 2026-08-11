#!/bin/bash
# PreToolUse hook: enforce single-command Bash calls.
# Blocks:
#   - Compound operators: &&, ||, ;, trailing \ (line continuation)
#   - Dynamic command substitution: $(...), backticks
#   - Process substitution: <(...), >(...)
# Allows:
#   - Variable refs: $VAR, ${VAR}
#   - Arithmetic: $((expr))
#   - Pipes and redirects: | > < >> 2>&1
# Rule: explicit, one-at-a-time, no nested or self-generated content.
# Scripts on disk may use anything; this hook only inspects Bash tool call strings.

CMD=$(jq -r '.tool_input.command // empty')

if [ -z "$CMD" ]; then
  exit 0
fi

# Check 1: compound operators
if echo "$CMD" | grep -qE '&&|\|\||;[^;]|\\$'; then
  cat <<'EOF'
{"decision":"block","reason":"Compound bash command detected (&&, ||, ;, or \\ continuation). Use separate Bash tool calls — one command per call. Parallel calls are fine for independent commands."}
EOF
  exit 0
fi

# Check 2: command or process substitution
# Regex notes:
#   \$\([^(]   matches $( NOT followed by (  — blocks $(cmd) but allows $((expr))
#   `          any backtick (command substitution)
#   <\( / >\(  process substitution
if echo "$CMD" | grep -qE '\$\([^(]|`|<\(|>\('; then
  cat <<'EOF'
{"decision":"block","reason":"Dynamic substitution detected ($(...), backticks, or <(...)/>(...))). Precompute values in a separate Bash call and pass literals. Rule: explicit over implicit, no self-generated content. Variable refs ($VAR, ${VAR}) and arithmetic ($((expr))) are fine."}
EOF
  exit 0
fi

exit 0
