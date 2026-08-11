# Security and disclosure

## Reporting

Email **michal@onedroid.ai**. We reply within one business day.

Please report privately first — do not open a public issue — for anything in the
categories below. We will confirm receipt, agree a disclosure timeline with you,
and credit you unless you prefer otherwise.

## What we especially want to hear about

This repository is a **method**, not a running service, so the interesting
vulnerabilities are unusual. Two classes matter most:

### 1. Disclosure failures — something published that should not have been

If you find a credential, an internal hostname, a cluster identifier, a client or
patient landmark, or anything identifying a person, **report it privately and
immediately.** Include the path, and whether you found it in the working tree or in
git history — the fix is very different in each case.

A leak in git history cannot be fixed by deleting the file. It requires rebuilding
the repository from a fresh `git init`, which is why
[`CONTENT-BOUNDARY.md`](CONTENT-BOUNDARY.md) insists the repo is built by selection.

### 2. Gate failures — a control that reports success without doing anything

`boot-kit/scripts/publish-gate.sh` is the control that stops class 1. If you can
construct input it *should* catch and does not, that is a security bug, not a
cosmetic one — a gate that supplies false assurance is worse than no gate, because
people stop looking.

Two real examples, both fixed, both of this shape:

- `P3` matched infrastructure identifiers but never the literal product name, and
  printed `RESULT: CLEAN — safe to publish` on a tree containing 29 landmark hits.
- `P2` used `\bmrn\b`. `git grep -E` is POSIX ERE with no PCRE: `\b` compiles
  without error and matches zero lines. The PHI scan had never been able to fire.

Both passed for their entire existence. Neither had been tested against an input it
must catch.

## Scope

In scope: the gate scripts, the hooks, the lock/verify tooling in `boot-kit/`, and
any content in this repository that should not be public.

Out of scope: the security of systems you build *using* this method, and the
behaviour of any AI model or agent harness that consumes these skills. The method
explicitly treats agents as untrusted — see
`reference/operating-agents-promise-theory.md`.

## A note on the threat model

The skills here instruct autonomous agents. If you can construct a prompt-injection
that makes an agent following these skills take an action the skill forbids —
particularly around the hard stops (pushing protected branches, deploying, outbound
communication) — we want to know. Treat it as in scope.
