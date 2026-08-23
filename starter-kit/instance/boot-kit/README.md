# boot-kit — what your harness loads at session start

Four pieces, three of which you install by hand exactly once. They are separate files
because they are installed by different mechanisms and fail in different ways, and a
single "config" that mixed them would hide which one is broken.

| file | what it is | how it gets installed |
|---|---|---|
| `hooks/df-instance-start.sh` | SessionStart hook: which instance, is it installed, what is running | declared in `loom.lock.json`, copied by the installer |
| `settings.template.json` | the entry that registers that hook | **merge by hand** into your harness settings |
| `mcp.template.json` | your hub, as a URL variable and an env-referenced token | **merge by hand** into your harness config |
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

### Known limit: the installer resolves hook sources under `vendor/` only

`hookSources` paths are resolved relative to your vendor directory, so a hook you write
*inside your instance* cannot be installed by re-running `install.sh` — it has nowhere to
resolve from. To ship your own hooks today, put them in a repo, add it to `upstreams`, and
point `hookSources` at the vendored path. This is a real gap, written down rather than
worked around: a second resolution rule for local paths would mean two ways to say where a
hook comes from, and two ways to say one thing is how the answers start disagreeing.

## The hub

`mcp.template.json` ships an unresolvable placeholder for the hub URL and an environment
reference for the token, and neither is an oversight.

A default that resolves would point your sessions at a host you never chose. And writing
the token as `${DF_HUB_TOKEN}` rather than a literal means **hub auth is inherited from the
environment** — which is the part that bites: a headless or scheduled run reaches the hub
only if that variable is exported in the process that spawned it. Otherwise the child boots
cleanly, fails every write, and keeps going. Export it in your shell profile before
launching anything unattended.

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
