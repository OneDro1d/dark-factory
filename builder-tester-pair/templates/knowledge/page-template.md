# Knowledge page templates

Copy the block for the page's kind. Every factual sentence cites `repo/path/file.ext:LINE`; anything you could not
prove from the code goes under "Open questions". File name: `<kind>--<slug>.md` in `<drafts>/<area>/`.

## Header (every kind)
```
# <Title>
kind: service|flow|rules|links|concept|bug · app: <app from pair.yaml>|cross · verified-at: <app> <commit>[, <app> <commit>]
applies-to: <branch/line this page describes>   (only when more than one line runs in production)
```

## service
```
## What it is (2-4 sentences, cited)
## Inputs / outputs
   HTTP routes (method, path, auth, request/response shape, status codes) · messaging (exchange/topic, routing key,
   queue, message type, who publishes/consumes) · DB tables touched · blob/object paths · files ·
   config keys (name, source, default, effect)
## How it works — numbered steps, each cited
## Requirements & conditions — every rule, branch, validation, limit, timeout, retry, status transition, error
   code: WHERE enforced (file:line) and WHAT happens on each side
## Links — calls / called-by / publishes-to / consumes-from (exact names)
## Failure modes & known traps (cited; bad input, broker loss, DB loss)
## Doc drift (doc says X at a:b, code does Y at c:d)
## Open questions
```

## flow
One business action end to end across services, each hop cited.
```
## Trigger (who starts it, how)
## Steps — numbered, one hop per step: service · what it does · cited
## Terminal states — each one, and how a caller observes it (status code, row, message, UI)
## Failure paths — where it can stop, what is left behind, how it is retried or cleaned up
## Open questions
```

## rules
A table, one row per rule. Testers read this page to plan checks.
```
| rule id / name | condition | enforced at (file:line) | outcome | error code / message |
|---|---|---|---|---|
```

## links
Who calls whom, over what.
```
| from | to | how (route / queue / topic / table / file) | sync or async | cited |
|---|---|---|---|---|
```

## concept
A domain idea several services share (a status model, an identifier scheme, a tenancy rule), with every place it
is defined or enforced, cited.

## bug
One page per fixed bug. Link it to the service page and the ticket.
```
## Symptom — what a user or system saw (no customer data)
## Root cause — file:line at the broken commit, in plain words
## Fix — PR + commit, and the behaviour that changed (before → after, cited at the fixed commit)
## Guarding test — the test id(s) that now fail on the old behaviour
## Recurrence sign — what to look for if it ever comes back (log line, metric, status)
## Links — FIXES <ticket>, service page, requirement node
```

## Engram
When a page passes the adversary sample, write it to the knowledge namespace (`engram.knowledge` in pair.yaml)
with `kind: knowledge`, the page's title as the Engram title, and links: requirement `REQUIRES` page; service page
`ENFORCES` rules page; flow `USES` service; caller `CALLS` callee; bug page `FIXES` ticket. Mirror every REQUIRES
link into `<library>/graph/edges.jsonl` as `{"from_title", "to_title", "relation", "evidence"}` —
`knowledge-refresh impact` reads that file.
