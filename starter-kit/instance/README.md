# starter-kit/instance — one machine, one instance

The path from a clone of this repo to a working Dark Factory session on **your** laptop,
against **your** hub. It is a sibling of `starter-kit/`'s org-layer generator, not a
replacement for it — the two answer different questions:

| you want | use |
|---|---|
| one machine, one person, running the method now | **this directory** |
| a whole org: a shared layer plus a per-developer tier | `starter-kit/new-org-layer.sh` |

An instance made here can be folded into an org layer later: both are lockfiles, and
the org layer's only extra move is to pin a shared Tier 2 between you and Tier 1.

## Ten-minute path

```sh
git clone https://github.com/OneDro1d/dark-factory.git
cd dark-factory
bash starter-kit/instance/bootstrap.sh my-instance
cd ../my-instance
$EDITOR loom.lock.json      # codeRoot, codeLayout, then the skills and hooks you want
bash install.sh
```

`bootstrap.sh` writes the directory and resolves the Tier-1 pin from the remote **now**.
`install.sh` is the re-runnable half: fetch at the pins, copy the engine in, install
skills and hooks, put `df-mission` on PATH, then verify. It ends by naming what no
installer can do for you.

## What is here

| file | what it is |
|---|---|
| `bootstrap.sh` | run once. Generates your instance directory beside this checkout. |
| `install.sh` | run whenever. Copied into the instance; that copy is the one you use. |
| `loom.lock.json.template` | the instance lockfile — the authority for what is installed. |
| `dot-gitignore.template` | becomes the instance's `.gitignore`. |
| `boot-kit/` | what the harness loads at session start: the SessionStart hook, the settings and hub templates, the output style. See `boot-kit/README.md`. |

## Two rules the shape depends on

**The lockfile is the authority; the installer is only mechanism.** Anything on disk that
the lockfile does not declare is installed by nothing and reported by nothing, so it does
not exist. `lock-verify.sh` checks both directions, and the second one — every vendored
directory is declared — is the one that usually goes missing.

**Pin commits, never branches.** A branch moves under you between two installs of the
"same" instance, and it moves most while it is under review, which is exactly when people
onboard onto it. `bootstrap.sh` resolves a SHA; an unresolved ref is written loudly.

## What the installer will not do for you

Three of the four boot-kit pieces are installed by hand, and they stay that way. The
session hook is declared in the lockfile and copied from the vendored upstream like any
other hook. The settings entry, the hub config and the output style each land in a file
shared with everything else you run — and a script that rewrites those silently removes
another tool's configuration, with the loss showing up much later as behaviour that used to
happen and now does not.

`install.sh` prints all three on **every** run, not once, so a green install is never read
as a complete setup. `boot-kit/README.md` says which is which and why.

## Still to come

`START-HERE.md`, `CLAUDE.md`, `AUTHENTICATION.md` and a worked example mission are separate
pieces of the same build. This directory is the skeleton they hang on.
