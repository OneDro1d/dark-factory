---
name: codebase-understanding
description: Navigate the codebase cheaply by reading the context store first, not re-scanning the repo. Use at the start of any investigation, feature, or review to locate the relevant service/file fast and with minimal tokens. Triggers on "where is", "how does X work", "understand the code", "find the service for".
allowed-tools: Read, Grep, Glob, Bash
---

# Codebase Understanding (read-first, low-token)

Goal: locate the relevant code in the fewest tokens. NEVER scan the whole repo to answer a question the context store already answers.

## Order of reading (stop as soon as you have what you need)
1. `.claude/context/SERVICE-MAP.md` — which service/db/queue/API owns this area.
2. `.claude/context/FINDINGS.md` — is this already known/solved?
3. `.claude/context/DECISIONS.md` — is the current behavior intentional?
4. The ONE relevant `<service>/CLAUDE.md` — contracts, key files, gotchas.
5. The shared-models `CLAUDE.md` — only when tracing a routing key / RPC across services.
6. Source — targeted, by `file:line` from the above, via Grep/Read. Not whole-file dumps unless necessary.

## Cheap search patterns
- Routing key / RPC: `grep -rn "<routing.key>" <service>/` then open the dispatcher.
- A symbol: `grep -rn "MethodName\|TypeName" <service>/ --exclude-dir={obj,bin}`.
- A flow: start at the SERVICE-MAP "In → Out" column, follow the routing key to the next consumer.

## Output
A short "where it lives" answer: service, file:line, and the one-line role. Do not paste large code blocks — cite locations.

## Don't
- Don't re-derive the architecture; it's in SERVICE-MAP/CLAUDE.md.
- Don't read every service. Read the one(s) the map points to.
