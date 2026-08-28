# boot-kit — what your harness loads at session start

Four pieces, three of which you install by hand exactly once. They are separate files
because they are installed by different mechanisms and fail in different ways, and a
single "config" that mixed them would hide which one is broken.

| file | what it is | how it gets installed |
|---|---|---|
| `hooks/df-instance-start.sh` | SessionStart hook: which instance, is it installed, what is running | declared in `loom.lock.json`, copied by the installer |
| `settings.template.json` | the entry that registers that hook | **merge by hand** into your harness settings |
| `mcp.template.json` | a default public hub, and an env-referenced token | **merge by hand** into your harness config |
| `output-style.md` | the working register: evidence-first, stop at the irreversible | **copy by hand** to your output-styles directory |

Only the first is automatable. The other three land in files shared with everything else
you run, and an installer that rewrites those is an installer that silently deletes another
tool's configuration. `install.sh` prints them as unfinished on **every** run rather than
once, so a green install is never mistaken for a complete setup.

## The hook

```sh
printf '{"cwd":"%s"}' "$PWD" | bash hooks/df-instance-start.sh | jq .
```

Run it before you register it. A SessionStart hook that errors, or prints anything that is
not JSON, is discarded **silently** — so a broken hook and a hook with nothing to say look
identical from inside the session.

It answers three questions a fresh context window cannot derive:

- **which instance is this** — the lockfile's name, and the agent's own name if it has one
- **is it actually installed** — read from the artefact the installer writes, not from the
  lockfile's intention. A lockfile can be perfect while nothing is installed, and every
  symptom of that surfaces somewhere unrelated: a missing command, an unknown skill, a gate
  that never fired.
- **is anything running** — every mission under `.df/missions/` that has a state on disk

Outside an instance it emits `{}` and injects nothing. That is deliberate: a hook that adds
noise to unrelated sessions gets turned off, and a hook that is off protects nothing.

### Two things that catch people

**Hooks are COPIED, not symlinked.** Editing this kit's copy changes nothing until you
re-run `install.sh`. Skills behave the opposite way, which is why this is worth stating
twice.

**A hook only takes effect in a NEW session.** Hooks are read once, at session start.
"My hook edit did nothing" is almost always one of these two.

**`install.sh` does NOT wire hooks.** It copies them and never touches `settings.json`.
Claude Code runs a hook only because a `settings.json` event chain names it, so a hook can
be declared, installed, hash-verified and completely **inert**. On disk is not on duty.
Wiring is a human step, every time, and nothing used to check it — `lock-verify` L9 does now.

### Declared, installed, and still not running

`lock-verify` checks the hook directory in both directions, added 2026-08-29 after four
machines in the reference estate were measured:

- **L8** — every hook present in `~/.claude/hooks` must be declared in the lockfile. This
  is L2's question asked of hooks, and until it existed a hand-copied hook could work for
  months while being installed by nothing and restored by nothing. All five instance
  records in that estate declared the same five hooks — this repo's own set — and between
  7 and 13 more per machine were undeclared, including the hooks supplying identity and
  memory. Every one of them passed L1–L7 and printed `LOCKED`.
- **L9** — every declared hook must appear in a live `settings.json` (or
  `settings.local.json`) event chain, and every wired path must exist on disk.

If a declared hook genuinely should not be wired — it is invoked by another hook, or it is
staged ahead of its chain — record it in `install.hooksUnwired`, a map of hook name to a
**reason string**:

```json
"install": {
  "hooks": ["a.sh"],
  "hookSources": { "a.sh": "upstream:dark-factory/hooks/a.sh" },
  "hooksUnwired": { "a.sh": "a helper the session-start hook calls, never an event chain" }
}
```

The reason is not decoration. An empty reason is itself reported as drift: an exception
nobody can audit is a silent failure wearing a lockfile key, and a gate with a free mute
button becomes a gate people learn to ignore.

### Where a source can point

A `hookSources` (or `skillSources`) value takes one of three forms:

| value | resolves against |
|---|---|
| `local:boot-kit/hooks/mine.sh` | **your instance** — the directory holding the lockfile |
| `upstream:dark-factory/hooks/x.sh` | your vendor directory |
| `dark-factory/hooks/x.sh` | your vendor directory — the bare form, and the one every existing lockfile uses |

`local:` is how you ship a hook or a skill of your **own**: write it inside your instance,
point at it, re-run `install.sh`. Without it an instance cannot own a hook at all — it
would have to push its own file into some other repo and vendor it back.

This was deliberately **one** rule and not two: the value carries a scheme, so there is
still a single place that says where a hook comes from. `local:` is resolved against the
**lockfile's** directory, never against the installer's own location — which is what makes
it safe when the installer itself is the vendored copy.

A source containing `..` is refused rather than normalised. A `..` could not escape before,
because every source was confined to `vendor/` by construction.

## The hub

`mcp.template.json` ships a **working default hub** and an environment reference for the
token, and the split is deliberate.

Until 2026-08-24 the URL was an unresolvable placeholder too, on the reasoning that a
default which resolves points your sessions at a host you never chose. That reasoning holds
for a *private* default and not for a public one — and the cost of it was a kit a stranger
could not finish. So the template now names the free public hub, and keeps the choice: see
`$bringYourOwnHub` in the file for how to point it somewhere else, and note that the method
still works with no hub at all.

**The path is the part people get wrong.** A personal access token uses `/agent/mcp` with
**no** hub slug — the token is bound to a hub when you create it, and the server resolves it
from that. The `/hub/<slug>/mcp` form is for browser OAuth, where the slug is what selects
the hub. Sending a token to the OAuth form fails with `ERR_SCOPE_UNAVAILABLE` unless the
slug happens to match, and the vendor's docs call getting this backwards the most common
wiring mistake: <https://docs.onedroid.ai/endpoints>.

The token stays a reference. Writing it as `${DF_HUB_TOKEN}` rather than a literal means
**hub auth is inherited from the environment** — which is the part that bites: a headless
or scheduled run reaches the hub only if that variable is exported in the process that
spawned it. Otherwise the child boots cleanly, fails every write, and keeps going. Export
it in your shell profile before launching anything unattended. The vendor's guidance is the
same: a password manager or secret store, never chat, git, or a shared doc —
<https://docs.onedroid.ai/tokens>.

Prove it works rather than assuming it: `python3 boot-kit/scripts/df-preflight.py --report`
makes a live call against every configured hub. A present `Authorization` header proves
nothing — tokens expire, and an expired one looks exactly like a working one until
something needs it.

## The output style

`output-style.md` is the working register: claims carry their evidence, `unknown` is never
collapsed into `drift`, and anything irreversible stops for a human. Copy it into your
harness's output-styles directory and select it. It is a starting point — edit it, and
expect to, because a register that does not match how you actually work is one you will
stop reading.

## Never emit a secret

Hook output is copied into the transcript verbatim. Anything a hook prints is published to
wherever that transcript goes. `df-instance-start.sh` reads the lockfile and the mission
directory and nothing else; its test suite asserts that against the **source**, not the
output, because a check on the output only holds for the inputs someone thought to try.

## Tests

```sh
bash tests/test-boot-kit.sh     # prints a literal pass/fail count
```

Everything runs in a scratch directory. Nothing in this suite reads or writes your real
harness config — a test that has to touch it is a test nobody runs twice, and one whose own
failure would be dangerous.
