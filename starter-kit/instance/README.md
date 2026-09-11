# starter-kit/instance — the generator for a personal kit

This directory makes **kits**: one private repo per person, holding that person's agent setup,
with one record per machine. It is a sibling of `starter-kit/`'s org-layer generator:

| you want | use |
|---|---|
| one person's agent, on each of their machines | **this directory** |
| a whole org: a shared layer plus a tier per developer | `starter-kit/new-org-layer.sh` |

## How to start

Open Claude Code in a clone of this repo and tell it: **"Read
`starter-kit/instance/START-HERE.md` and execute it."** [`START-HERE.md`](START-HERE.md) is the
runbook. It checks the tools, has the human choose a kit, makes a private repo, adds a record
for this machine, installs, walks through the sign-ins and validates. Each step ends with a
check the agent runs before moving on.

`bootstrap.sh` copies `START-HERE.md` and [`AUTHENTICATION.md`](AUTHENTICATION.md) into every
kit it makes, byte for byte, so the same instruction works from inside any kit. What is specific
to one kit goes in its `KIT.md`, rendered from `KIT.md.template`.

## What is here

| file | what it is |
|---|---|
| [`START-HERE.md`](START-HERE.md) | the runbook. The same file in every kit; it names no commit |
| [`AUTHENTICATION.md`](AUTHENTICATION.md) | the hub, the token and the connectors |
| `KIT.md.template` | becomes the kit's `KIT.md`: who it is for, what it connects to, the access it needs, what cannot be undone, its machines |
| `bootstrap.sh` | run once. Makes a new kit directory beside this checkout and pins the method at the current commit |
| `install.sh` | run on every machine, any number of times: `bash install.sh --lock=instances/<machine>/loom.lock.json`. Copied into the kit |
| `VALIDATE-INSTALL.md` | the by-hand form of START-HERE step 6 |
| `loom.lock.json.template` | the kit's root record, and the base every machine's record is copied from |
| `dot-gitignore.template` | becomes the kit's `.gitignore` |
| `CLAUDE.md.template` | becomes the kit's `CLAUDE.md`. A template, so that no `CLAUDE.md` sits here and gets loaded into sessions about the generator |
| `boot-kit/` | the settings, hub and output-style templates, and the kit's own tests. See [`boot-kit/README.md`](boot-kit/README.md) |
| `example-mission/` | the worked example, copied into each kit as `.df/missions/EXAMPLE-FIRST-RUN/`. Its own `HARD-STOPS.md` confines every write to its directory |
| `tests/` | this directory's suites |

## Rules the shape depends on

**The record is the authority; the installer is only mechanism.** Anything on disk that no record
declares is installed by nothing and reported by nothing. `lock-verify.sh` checks both
directions.

**One record per machine.** The installer takes `--lock=instances/<machine>/loom.lock.json` and
hands that record to every step, so the record that was installed is the record that was
verified. A bare `bash install.sh` reads the root record.

**Pin commits, never branches.** A branch moves between two installs of the same record.
`bootstrap.sh` resolves a commit and says where it came from.

**What no installer does for you** stays manual and is printed on every run: the harness settings
entry, the hub config and the output style each land in a file shared with other tools, and a
script that rewrote them would silently delete their configuration.

## Tests

```sh
bash tests/test-bootstrap-docs.sh            # a new kit carries its runbook, KIT.md and CLAUDE.md
bash tests/test-start-here-doc.sh            # the runbook: executable, self-contained, no leaks, no pinned commit
bash tests/test-authentication-doc.sh        # no credential-shaped literal reaches the hub page
bash tests/test-install-instance-record.sh   # --lock= reaches every step of the install
bash tests/test-example-mission.sh           # the worked example lands where df-mission looks
bash boot-kit/tests/test-boot-kit.sh         # the boot-kit pieces
```

Each prints a literal pass/fail count and works in a temp directory. `boot-kit/scripts/run-tests.sh`
at the repo root runs them all.
