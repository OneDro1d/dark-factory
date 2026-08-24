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

### The hub this kit points at by default, and the memory behind it

`boot-kit/mcp.template.json` ships pointing at **OneDroid Synapse**, because a kit whose
setup step is *"obtain a hub from somewhere"* is a kit a stranger cannot finish. Anyone can
sign up; the vendor states one account covers both products below and is free for
individuals and small teams. It is a **default, not a requirement** — [§2](#2-pointing-it-at-a-hub)
is how you point it elsewhere, and [*What a hub is not*](#what-a-hub-is-not) above is why
you may point it nowhere.

> **Synapse** is a governed MCP gateway. Your agents connect to one URL instead of holding a
> dozen sets of credentials, and every tool call is authenticated, policy-checked, and
> written to an audit log you own.

> **Engram** is versioned agent memory that lives in your own Postgres. Context that
> survives the session, is portable between agents, permissioned, and yours to keep.

<a id="engram"></a>Engram is the one upstream the method itself leans on — the stages recall
prior work rather than rediscovering it, and that is the store they recall from. It is
reachable directly at its own endpoint, or as an upstream *through* Synapse, which is how it
ends up governed and audited alongside everything else in the hub. Elsewhere in this repo
you will see `engram` named in passing as a place a stage writes to; **this is the thing it
means**, and none of it is required — a stage that cannot reach a memory store records
locally and says so.

What it is *not*: not a vector blob (retrieval is hybrid semantic-plus-keyword over a typed
object graph, with explicit supersedes/references relations), and not tied to one harness or
model. Bring-your-own-Postgres is a first-class path, for the same reason bring-your-own-hub
is: <https://engram.onedroid.ai>, and <https://docs.onedroid.ai/engram> for the detail.

---

## 2. Pointing it at a hub

`boot-kit/mcp.template.json` ships a **working URL and no credential**. Copy the
`mcpServers` block into your harness config — Claude Code reads `~/.claude.json` — export
the token, and you are connected. If you use more than one hub, add one object per hub
rather than merging them.

| what | ships as | yours to change? |
|---|---|---|
| the server key (`synapse`) | the local name your harness shows | yes — name it for the hub, not for the tools behind it |
| the `url` | the documented default, `https://synapse.onedroid.ai/agent/mcp` | yes — see *bring your own hub* below |
| `${DF_HUB_TOKEN}` | **leave this exactly as written** — an environment reference, not a value | no. See [§3](#3-the-token-is-an-environment-reference) |

**Why there is a default at all**, given that a default which resolves points your sessions
at a host you never chose. That reasoning is sound and it is why the kit shipped a
placeholder for a long time — but it is an argument against a *private* default. This one is
public, free to sign up for, named on the page you are reading, and one line to replace. The
cost of the placeholder was a reader who could clone the kit and not finish it, which is the
worse failure.

### The path is the part people get wrong

There are two ways to authenticate, and **each has its own URL**. Sending one form's
credential to the other form's path is, by the vendor's own account, the most common wiring
mistake:

| | personal access token | browser OAuth |
|---|---|---|
| URL | `https://synapse.onedroid.ai/agent/mcp` | `.../hub/<slug>/mcp` |
| what selects the hub | the token — it is bound to one when you create it | the slug in the path |
| use it for | Claude Code, CI, headless agents, containers | a desktop app or a browser |

This kit is the **token** avenue, so it is `/agent/mcp` with **no slug**. Do not infer the
path from the shape of some other MCP URL you have seen; a token sent to a slugged path
fails with `ERR_SCOPE_UNAVAILABLE` unless the slug happens to match its hub, and there is no
reason to prefer that form for a token client. Why the asymmetry is real rather than
arbitrary: <https://docs.onedroid.ai/endpoints>.

### Bring your own hub

Replace the `url` with your own MCP endpoint and rename the server key to match. **Your
provider tells you the exact path** — do not assume it takes the same shape as the default,
which is specific to how one product separates token auth from OAuth. Everything else on
this page applies unchanged: the token is still an environment reference, the boundary rules
in [§6](#6-one-hub-per-boundary) still hold, and [§5](#5-verify-it-live-a-header-proves-nothing)
still proves it.

And you can run no hub at all — delete the file. You lose shared memory and connectors;
nothing else in the method depends on it.

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

### Getting one, and what the kit will not tell you twice

For the default hub: sign in, check the hub picker is on the hub you mean, then
**Manage → API Tokens → Create token**. You are shown the plaintext **once** — copy it
before dismissing the dialog. The full model — how many you may hold, what rotate does that
revoke does not, how to choose an expiry — is one page and it is the vendor's:
<https://docs.onedroid.ai/tokens>. This kit deliberately does not restate it. Two copies of a
credential model drift apart, and then a reader has no way to tell which one is stale.

Two things from that page are worth surfacing here, because they change what you do next:

- **Custody is the product's rule, not this kit's house style.** Password manager or secret
  store; *never chat, git, or a shared doc*. That is why the template writes
  `${DF_HUB_TOKEN}` and why [§8](#8-what-never-gets-written-down) is absolute.
- **Permissions are inherited and live, not frozen at creation.** The token carries whatever
  role you currently hold in its hub. Change the role and the token's access changes with it,
  immediately, with nothing to re-issue — which is also why a token for a hub you have left
  simply stops working rather than lingering.

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
  write scope, and a credential that cannot write turns a whole class of mistake into an
  error message. Note this is a statement about **upstream** credentials, which you scope in
  the upstream. The hub token is different — see below.
- **An attached connector is not a working connector.** Attachment and authorization are
  separate, and a stale refresh token looks identical to a live one until a tool is called.

### Giving an agent less access than you have

The intuitive move is to look for a narrower credential, and on the default hub there is no
such control to find: the credential inherits your live role and there is no permission
switch on it. **Narrowing is a property of the role and of the hub's tool toggles, not of
the credential.** So the order is: turn tools off under **Admin**, or put the work in a group
with a narrower role — *then* mint. Doing it the other way round means hunting for a checkbox
that does not exist and concluding the product is missing a feature.

**Inheritance runs both ways, and only one of them is loud.** Narrowing your role takes
access away immediately and tells you so the next time a call returns `403`. Widening it says
nothing at all: every token you have **already minted** gains the new access at the same
moment, including the narrow one you minted for a single job months ago and forgot. Nothing
is re-issued, so there is no event to notice and no list to review.

So the thing to audit is the role, not the tokens — and the moment to prune tokens you no
longer use is when your role *widens*, which is exactly when nothing is failing to prompt you.

Details, and the reasoning for that design: <https://docs.onedroid.ai/tokens>.

If your hub is not the default one, ask your provider which of the two models it uses. They
differ, and assuming the wrong one is how an agent quietly ends up with your full access.

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
| `ERR_SCOPE_UNAVAILABLE` | a token sent to a slugged URL. Use the slug-free token path — [§2](#the-path-is-the-part-people-get-wrong) |
| an agent can suddenly do more than it could last week | nobody re-issued anything — your role in that hub widened, and every token you had already minted widened with it |
| a token that used to work now returns `403` | your membership or role in that hub is gone. This is by design and there is nothing to re-issue |
| connected fine, but zero tools appear | the hub has no upstreams enabled — auth is not the problem. On the default hub only an admin can enable them, so if you were *invited* into someone else's hub this is not yours to fix; ask them |

For the default hub, the vendor keeps the authoritative failure table — including the two
`401`s, which separate *the token is wrong* from *the client never sent the header*:
<https://docs.onedroid.ai/troubleshooting>.

---

## Related reading

- [`boot-kit/README.md`](boot-kit/README.md) — the four boot-kit pieces, and which of them
  no installer will ever do for you
- [`START-HERE.md`](START-HERE.md) — the ten-minute path from clone to a first session
- [`README.md`](README.md) — this directory's shape and the two rules it depends on

For the default hub, the vendor's own pages — authoritative, and deliberately not copied
into this kit:

- <https://docs.onedroid.ai/quickstart> — sign-up through to a first verified call
- <https://docs.onedroid.ai/endpoints> — the two auth avenues and why each has its own URL
- <https://docs.onedroid.ai/tokens> — minting, custody, expiry, rotate vs revoke, narrowing
- <https://docs.onedroid.ai/engram> — the memory store described in [§1](#engram)
