# AUTHENTICATION.md — the hub, the token, and the connectors

Everything here is about **one boundary**: what your sessions are allowed to reach, and
what proves they are allowed to reach it. Nothing in this file is a secret and nothing in
it should ever become one — if a value belongs to you rather than to the method, this page
tells you where it lives instead of writing it down.

Read this **before** you point the kit at a hub. [`install.sh`](install.sh) prints that
instruction on every run for the same reason: pointing sessions at a host is the one setup
step whose mistake is invisible from inside the session.

---

## 1. What a hub is

A **hub** is a single MCP endpoint that fans out to many upstream tools on your behalf. You
configure one URL; behind it sit whatever connectors you have attached — a memory store, an
issue tracker, a chat workspace, a document store, a database, a CI provider. Your harness
sees one server with a long tool list.

That is the whole idea, and it has two consequences worth holding onto before you set one
up:

- **The tool list is not stable; the hub is.** Connect or disconnect an upstream and the
  tool list changes underneath a config that did not change. So name each server for the
  hub it points at, never for the tools behind it. `mcp.template.json` says the same thing
  and it is the same reason.
- **A hub is a merge point.** Everything reachable through one hub is reachable by every
  session pointed at it. That is convenient and it is also exactly how content crosses a
  boundary you meant to keep — see [§6](#6-one-hub-per-boundary).

### What a hub is *not*

It is **not required**. The method — the stages, the control loop, the evidence gate, the
mission frame — runs entirely on your local files and your own git. A hub adds shared
memory across sessions and machines, and connectors to systems you already use. If you do
not have one, delete `boot-kit/mcp.template.json` and carry on; nothing else in this kit
depends on it.

It is also **not an authorization system for your data**. The hub authenticates *you to
it*. Each upstream still authorizes the hub separately, with its own credential and its own
scopes. A hub token that works proves nothing about whether any particular connector is
attached, authorized, or still valid.

---

## 2. Pointing at your own

`boot-kit/mcp.template.json` is a **template, not a working config**, and that is
deliberate. A default that resolved would point your sessions at a host you never chose,
and the first symptom would be a hub you did not intend answering questions about work you
did not intend to send it.

It carries three things you fill in:

| placeholder | what it is | where it comes from |
|---|---|---|
| `__HUB_NAME__` | the local name your harness uses for this server | you choose it; name it for the hub, not the tools |
| `__HUB_URL__` | the MCP endpoint the hub serves, usually ending in `/mcp` | your hub provider gives you this. There is no default and there will never be one |
| `${DF_HUB_TOKEN}` | **leave this exactly as written** — it is an environment reference, not a value | see [§3](#3-the-token-is-an-environment-reference) |

Copy the `mcpServers` block into your harness config — Claude Code reads `~/.claude.json` —
and fill in the first two. If you use more than one hub, add one object per hub rather than
merging them.

Then prove it, rather than assuming it: [§5](#5-verify-it-live-a-header-proves-nothing).

---

## 3. The token is an environment reference

The template writes the credential as `${DF_HUB_TOKEN}` and not as the token itself. Two
reasons, and the second is the one people learn the hard way.

**(1) A config file travels.** It gets copied to a second machine, committed by accident,
screenshotted into a bug report, pasted into an issue. An environment variable does none of
those things. A literal token in a config is a token you will eventually have to rotate for
a reason you did not choose.

**(2) Auth is therefore INHERITED FROM THE ENVIRONMENT** — and this is the failure that
costs a whole unattended run. A headless, scheduled, or supervisor-spawned session reaches
the hub only if that variable is exported in the process that spawned it. If it is not, the
child **boots cleanly, fails every hub write, and keeps going**. There is no crash and no
error banner. You discover it when you go looking for work that was never recorded.

So:

```sh
# in your shell profile, not in any file this repo tracks
export DF_HUB_TOKEN='...'
```

and before launching anything unattended:

```sh
[ -n "${DF_HUB_TOKEN:-}" ] || { echo 'DF_HUB_TOKEN is not exported in THIS process' >&2; exit 1; }
```

`df-preflight` checks exactly this and reports it as its own finding class, because "the
config is correct" and "this process can use it" are different facts.

> **If a hub call fails auth in an unattended run, stop.** Do not work around it. A failure
> means that process cannot write to the tracker or to memory, so any work it goes on to do
> is invisible to whatever runs next — which is worse than not doing the work.

---

## 4. Connectors — what each one needs

Connectors are attached at the **hub**, not in this kit. The kit never holds an upstream
credential and has nowhere to put one. What you need per connector depends only on which of
three kinds it is:

| kind | what you supply | what to expect |
|---|---|---|
| **OAuth, interactive** | a browser sign-in, once, at the hub | the hub stores a refresh token. Re-consent when scopes change |
| **API token / PAT** | a token you mint in the upstream, scoped as narrowly as it will let you | expiry is yours to track; most upstreams will not warn you |
| **Service account / app credential** | a key pair or client secret, plus a grant in the upstream's admin surface | usually the only kind that survives the granting person leaving |

Three rules that apply to all of them:

- **Grant the narrowest scope the work needs, then widen when something actually fails.**
  Widening is a two-minute change with a visible trigger. Narrowing later never happens,
  because nothing ever fails to tell you a permission is unused.
- **Read-only where reading is the job.** Diagnosis, recall and status checks do not need
  write scope, and a read-only credential turns a whole class of mistake into an error
  message.
- **An attached connector is not a working connector.** Attachment and authorization are
  separate, and a stale refresh token looks identical to a live one until a tool is called.

### Interactive-only connectors are absent from headless runs — and that is `unknown`, not broken

Some connectors authenticate against **your** interactive account rather than against the
hub's own credential. Those do not exist in a headless session: there is no browser, and
nothing to consent with. A preflight that cannot see such a connector must report
`unknown` — *"could not probe"* — and never `drift`, which asserts a fact about the world.
Collapsing the two is how "nobody was logged in" gets written down as "this machine has no
such connector", and the record is then wrong in a way nothing later contradicts.

If your workflow needs one of these in an unattended run, the answer is a service-account
credential on the hub, not a workaround in the loop.

---

## 5. Verify it live — a header proves nothing

```sh
python3 boot-kit/scripts/df-preflight.py --report
```

This makes a **live `tools/list` call** against every configured hub. That distinction is
the point of the check: a present `Authorization` header proves only that a header is
present. Tokens expire, get revoked, and get rotated by someone else, and an expired one
looks exactly like a working one right up until something needs it.

Read the verdict, and read all three:

| verdict | means |
|---|---|
| `ok` | probed, and reality matches the record |
| `drift` | probed, and reality **differs** — a positive finding, and the only kind that justifies changing a record |
| `unknown` | **could not probe** — binary missing, network down, nobody signed in. This is not a fact about the world |

Only a positive `drift` should ever cause you to rewrite a lockfile. An `unknown` written
down as `drift` is a network blip recorded permanently as a property of your machine.

---

## 6. One hub per boundary

If you work across contexts that must not mix — different clients, different data
classifications, personal and professional — give each its **own hub, its own token, and
its own environment variable**. Separate hubs stay separate. A single merged hub is not a
boundary with a rule attached to it; it is one namespace where every session can reach
everything, and the rule lives only in whoever is remembering it at the time.

The same applies to memory. Shared recall is the main reason to run a hub at all, which is
precisely why the memory store must sit on the correct side of the line: anything written
in one context becomes recallable in every session pointed at that hub, including sessions
started for something else entirely, months later.

---

## 7. Rotation, revocation, and what to do after a leak

- **Rotate on a schedule you actually keep**, and rotate immediately if a token has been in
  a file, a screenshot, a paste, or a terminal recording.
- **Revoke first, replace second.** Replacing without revoking leaves a working credential
  in circulation, and it is the old one that leaked.
- **A leak into git history is not fixed by deleting the file.** Git keeps the object. Many
  hosts keep serving unreferenced objects by SHA long after the branch pointing at them is
  gone, so a rewrite does not reliably un-publish anything. Treat the credential as burned
  and rotate it; then fix the history because it is untidy, not because it is a remedy.

---

## 8. What never gets written down

The kit's own gates are built around this and it is worth stating plainly:

- No token, key, secret, cookie, or session id — in any file, comment, example, default
  value, test fixture, or commit message.
- No environment variable whose default resolves to a private host.
- Hook output is **copied into the transcript verbatim**. Anything a hook prints is
  published to wherever that transcript goes, so a hook must never read a credential — not
  even to check whether one is set to a non-empty value.

The one habit that generalises: when you need to show that something is configured, show
the **name** of the variable and whether it is set, never its value.

---

## Troubleshooting

| symptom | almost always |
|---|---|
| every hub call fails, nothing else is wrong | the token variable is not exported in **this** process — check the parent, not your interactive shell |
| worked interactively, fails under a supervisor or scheduler | same cause: the spawning process had a stripped environment |
| the harness starts fine but no hub tools appear | the config was edited after the session started; hub config is read once, at session start |
| one connector's tools are missing, the rest work | that connector is not attached or its authorization has lapsed — the hub token is not the problem |
| an interactive-account connector is missing in a headless run | expected. That is `unknown`, not `drift` — see [§4](#interactive-only-connectors-are-absent-from-headless-runs--and-that-is-unknown-not-broken) |
| `tools/list` returns entries but a specific tool call 401s | upstream scope, not hub auth |
| it all worked yesterday | a token expired, or someone rotated it. Neither announces itself |

---

## Related reading

- [`boot-kit/README.md`](boot-kit/README.md) — the four boot-kit pieces, and which of them
  no installer will ever do for you
- [`START-HERE.md`](START-HERE.md) — the ten-minute path from clone to a first session
- [`README.md`](README.md) — this directory's shape and the two rules it depends on
