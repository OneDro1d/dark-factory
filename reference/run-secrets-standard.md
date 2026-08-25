---
title: Run-Secrets Standard — one front door, and the agent is not on it
type: reference
status: living
honours: Prime Directives 5, 9, 10
---

# Reference: Run-Secrets Standard — one front door, and the agent is not on it

## TL;DR

**An app never carries its own run-secrets in git, in its image, or in a hand-applied
secret object. Run-secrets live in the platform secret store and are delivered to the
workload declaratively.**

That is the axiom. Everything below is why it holds and what it costs to break.

The second half matters as much as the first and is the half usually missing: **the coding
agent is never on the secret path.** A method that hands an autonomous agent a database URL
to "get the deploy working" has already lost the property the vault existed to provide.

## Scope

**In scope** — the secrets an application needs to **boot and run**: database connection
strings, message-bus credentials, identity-provider keys, signing and encryption keys,
registry pull credentials. One mechanism for all of them, across every app on the estate.

**Out of scope** — an app's *internal* credential features. A service whose product is
brokering third-party keys for its callers is doing product logic; that is untouched here.
For this standard it is just another app that needs a connection string to start.

Also out of scope: per-developer interactive credentials. Those are a genuine exception and
have their own section below — not because they are unimportant, but because they are not
app boot secrets and putting them in the vault gets both wrong.

## The shape, stated once

> **Secret store** = the environment's vault — one per environment, the single place a
> value exists.
> **Delivery** = a declarative reference committed to the app repo, reconciled by an
> operator into whatever the runtime mounts, which the workload consumes as environment or
> file.

The *reference* is in the repo. The *values* never are. Your organisation layer names the
concrete vault, the operator, and the auth mode — see the binding note at the end.

## Why — the properties this buys

- **One source of truth per environment.** No "is it in the manifest, the vault, or
  someone's password manager?" The question has one answer, and it is checkable.
- **Declarative and reproducible.** Rebuilding an environment re-materialises its secrets
  with no manual create-a-secret step. A secret that only exists because a human once ran a
  command is a secret that will be missing after the next rebuild.
- **Rotation is a one-liner.** Update the value in the vault; the operator refreshes on its
  interval; the workload restarts or re-reads. No redeploy, no code change, no coordination.
- **Audited and centrally revocable.** Vault access is logged. Killing a leaked credential
  is one action in one place, not a search across repos, images and clusters.
- **The blast radius of a leak is bounded and known.** You can answer "who could read this,
  and when did they" — which is the actual question after an incident.
- **The coding agent is never on the secret path.** The operator mounts secrets into the
  *app's* runtime, not into a developer's shell or an agent's context. So there is never a
  reason to paste a credential into a chat, a prompt, a transcript or a scratch file — and
  "there was no reason to" is a far stronger control than "we asked people not to".

That last property is the one this method cares about most, and it is *structural*. An
autonomous build loop reads and writes files, runs commands, and keeps transcripts. Any
secret it touches is now in places nobody enumerated. The fix is not redaction after the
fact; it is never putting the value on that path.

## The one exception: interactive, per-developer auth

**A per-user interactive tool authenticates as a person, not as an app.** Its "run
credential" is a developer's own session, obtained by signing in on first launch (a device
flow works headless), and persisted in the tool's home directory.

Two consequences, both easy to get wrong:

1. **Keep these out of the vault entirely.** They are per-person, not per-app. A shared
   vault entry for a personal session destroys the attribution that made it a *person's*
   credential, and it will be wrong for everyone but the one who put it there.
2. **The workspace `$HOME` must be on persistent storage,** or the token dies with the
   container and every restart becomes an interactive sign-in — which, in an unattended
   loop, presents as an unexplained hang rather than an auth error.

The test for which side of the line something falls on: *if this credential were revoked,
is the thing that breaks an application or a person?* Applications go in the vault. People
sign in.

## Conventions

- **Key naming: `<app>-<key>`.** One vault holds every app's run-secrets, disambiguated by
  prefix. This keeps the "one source of truth per environment" property literal — one
  vault, not one vault per app that you then have to enumerate.
- **One cluster-wide store rather than one per namespace.** Every app's reference points at
  the single store, so there is no per-namespace boilerplate to forget.
  **The trade-off, stated rather than hidden:** the store identity can read the whole vault.
  Pair it with access control on *who may create a secret reference*. That is acceptable
  where the trust boundary is already the platform's own access control, and it is not
  acceptable where namespaces are a tenancy boundary. Decide explicitly; do not inherit
  this by copying a dev cluster into production.
- **Auth mode by environment.**
  - **Development** — the simplest credential the platform offers. The trust boundary is
    platform access control plus operator-applied store credentials, and the simplicity is
    worth more than the marginal hardening.
  - **Production** — a workload-bound identity, so there is **no standing secret-store
    credential in the cluster at all**. The store proves who it is; nothing is stored to be
    stolen.
- **Never commit a real value.** The history of any secret-shaped manifest must show only
  placeholders and references. Enforce it with a merge gate that rejects a manifest
  containing a plaintext-looking credential — not with a convention, because a convention
  is exactly what fails at 2am.

⚠️ **A deletion does not remove git history.** If a real value ever lands in a commit, the
credential is compromised the moment the commit is pushed, and removing it in a later commit
changes nothing. Rotate it — treat the cleanup as hygiene, never as the remediation.

## Adding or rotating a run-secret — the low-friction path

Because run-secrets have exactly one front door, adding one and rotating one are the **same
single command** against the vault, and neither touches a developer's editor or an agent's
context:

```
<vault-cli> set  --store <environment-vault>  --name <app>-<key>  --value <...>
```

The operator syncs it into the runtime within its refresh interval. Wrap it in a
one-argument script if you like; sync it from wherever people already keep secrets if that
is where they will actually put them.

**Put the friction on the wrong path, not the right one.** A secret in git or pasted to an
agent should fail review and fail CI. The vault path should be one command. Any method
where the compliant route is harder than the non-compliant one is a method that describes
what people will stop doing.

## Migration checklist, per non-conformant app

1. Confirm every value exists in the environment vault under `<app>-<key>`.
2. Add the declarative reference (and the store, if absent) to the app repo.
3. Verify the materialised secret matches the hand-applied one **key for key** — a missing
   key presents at boot as a confusing runtime error, not as a missing secret.
4. Switch the workload to consume the managed secret, then delete the hand-applied one.
5. **Prove rotation works before closing.** Change one value in the vault and watch the
   workload pick it up. A migration that has never been rotated has not been tested; it has
   only been observed to start once.

## Anti-patterns

- **Values in the image.** Rebuilds and registry copies now carry the credential, and the
  registry's own access control becomes the secret's access control.
- **A hand-applied secret object.** Works, is invisible, and is missing after the next
  cluster rebuild — with no record of what it contained.
- **Secrets in CI variables only.** The value now lives in the CI system as well as the
  vault, and the two drift silently. If CI needs it, CI should read the vault.
- **Pasting a credential to an agent "just to unblock the deploy".** It is now in a
  transcript, a context window and possibly a log. Rotate it; do not reason about whether
  it leaked.
- **A vault per app.** Restores the enumeration problem the single store removed.
- **A `.env` file that is gitignored.** The ignore rule is one careless `git add -f` from
  useless, and the file is invisible to every audit that scans the repo.

## See also

- [`10-prime-directives.md`](10-prime-directives.md) — Directive 5 (trust explicit, scoped
  and observable), Directive 9 (execution under an explicit trust profile), Directive 10
  (operational knobs exposed — rotation is one).
- [`observability-standard.md`](observability-standard.md) — nothing unwatched exists,
  secrets included: a failed secret sync must surface somewhere an agent can query.
- Your organisation layer — the concrete vault, the operator that delivers from it, the
  auth mode per cluster, and the reference manifest shape. Those are bindings, and they
  belong beside your cluster names, not here.
