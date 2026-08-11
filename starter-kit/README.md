# starter-kit — build your own tiered agent environment

Everything needed to go from this public repo to **your organisation's own agent
environment** with per-developer instances. Generalised from a production rollout that
onboarded external developers in about ten minutes each.

## The tier model

```
Tier 1   OneDro1d/dark-factory        the generic method (this repo). Public.
                                      Nobody clones it directly — installers fetch it
                                      at a pinned commit.
Tier 2   your org layer               what your whole org shares: curated upstream
                                      skills, org skills, hooks, doctrine. The repo
                                      your developers clone.
Tier 3   one repo per developer       personal skills/hooks/doctrine + one pin that
                                      selects the Tier 2 version. Generated, never
                                      forked.
```

Two properties make this work:

- **Lockfiles are the authority; installers are only mechanism.** Every tier declares
  exactly what it installs. Content that exists on disk but is not in a lockfile is
  installed by nothing and reported by nothing — so it does not exist.
- **Tier 3 is generated, never forked.** An instance pins Tier 2 and delegates to its
  installer; it never copies the shared skill list, so there is nothing to merge and no
  second copy to drift. Taking an update is a one-line SHA bump.

## Stand up your org layer

```sh
git clone https://github.com/OneDro1d/dark-factory.git
cd dark-factory
bash starter-kit/new-org-layer.sh dark-factory-acme acme/dark-factory-acme ~/Code "Acme"
```

This generates `~/Code/dark-factory-acme`: an installer, an `org.lock.json` pinning
Tier 1 to a commit SHA resolved right now and listing Tier 1's current skills and hooks
explicitly, a Tier 3 generator for your developers, and onboarding docs. Curate the
lockfile, push it to your org, and point developers at its README.

## Design rules baked in (learned in production, kept on purpose)

1. **Pin commits, never branches.** A branch moves under you between installs — and it
   moves most while under review, exactly when people onboard onto it. Generators resolve
   SHAs at generation time; an unresolved ref is written loudly, never silently.
2. **A pin must be reachable from a remote branch.** After an upstream history rewrite the
   old pin still exists in local object stores, so every local check passes and the break
   surfaces only on the next fresh clone. `boot-kit/scripts/lock-verify.sh` (L6) checks
   the remote.
3. **Skills symlink, hooks copy.** Skill edits are live immediately; hook edits need a
   reinstall and a new session, because `__HOME__` is substituted per machine.
4. **The agent names itself.** `agentName` ships empty and is never defaulted. And the
   name never becomes a release, image tag, or ticket fixVersion.
5. **There is no single MCP prefix.** Two machines in one org can legitimately see
   different tool namespaces in the same week. Docs state observed shapes as data points
   to confirm, never constants to copy — an agent that wrongly concludes a system is
   unavailable may invent state rather than report the gap.
6. **Print what the installer cannot do.** Credentials, connectors, settings merges.
   A green install must never read as a complete restore.
7. **Verify the result on disk, not the script's belief.** The installers re-check
   symlinks resolve, hooks are executable, placeholders are substituted.

## Layout

```
starter-kit/
  new-org-layer.sh              generates your Tier 2 from the template below
  templates/tier2-org/
    org.lock.json               authority: T1 pin + curated skill/hook list
    install.sh                  self-contained installer (fetch T1, link, copy, verify)
    scripts/new-instance.sh     generates a developer's Tier 3, pinning T2 by SHA
    templates/tier3-instance/   what that stamps out (lockfile, installer, docs)
    docs/ONBOARDING.md          seven steps, written for a first-timer
```
