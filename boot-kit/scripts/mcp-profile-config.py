#!/usr/bin/env python3
"""mcp-profile-config.py — write a PROFILE-SCOPED MCP config for a headless iteration.

⛔ WHY THIS EXISTS. `df-supervisor.sh` passes `--setting-sources project`, which loads only
project-scoped settings. MCP servers are configured at USER scope (`~/.claude.json`), so that
flag silently removes EVERY MCP server from every worker. A worker then boots cleanly, has no
tracker, no memory and no observability, and cannot say so — it just does not write anything.

⚠️ THE FLAG IS STILL RIGHT AND IS NOT WHAT CHANGES. It exists to keep user-level SessionStart
hooks out of each child. Re-enabling user settings to recover MCP would drag the hooks back in
and pay their tokens twenty times over. The fix is to pass MCP EXPLICITLY:
`--mcp-config <this file> --strict-mcp-config`, which composes with `--setting-sources project`.

⚠️ SCOPED, NOT WHOLESALE. The binding rule is "the profile's hub ONLY — every other server
denied at launch", and the profile→hub rule is already defined in df-preflight.probe_mcp: a hub
belongs to a profile when its NAME STARTS WITH the profile string. The same rule is applied
here on purpose, so a hub cannot be in scope for the preflight and out of scope for the worker
that preflight cleared.

⛔ SECRETS — AND THE ESTATE'S OWN DOCUMENTATION IS WRONG ABOUT THIS. Loom's binding notes say
`~/.claude.json` holds `Bearer ${SYNAPSE_ONEDROID_TOKEN}` — an env-var REFERENCE, not a token.
MEASURED FALSE on the laptop 2026-09-05: both onedroid hubs carry LITERAL bearer tokens. So
this script copies real secrets, and the first version of it wrote them into a path under the
notepad — a git repo that is committed and pushed every session.

Therefore: values are copied verbatim, NEVER printed, the file is written 0600, and the script
REFUSES OUTRIGHT to write inside a git working tree. ⚠️ The refusal is not belt-and-braces. The
natural place to put a per-mission file is the mission directory, the mission directory is
inside the notepad, and the notepad is a repo whose whole purpose is to push — so the obvious
choice is the leaking one, and only a hard refusal catches it.

⚠️ Do not "fix" the doc by assuming env refs and skipping the guard. Both shapes are valid and
which one a machine has is not knowable from here.

⚠️ AND IT CHECKS THE ENVIRONMENT. A supervisor launched from a stripped environment spawns
children that boot cleanly, fail every hub call, and keep looping — the documented failure this
estate has already paid for. Every `${VAR}` referenced is checked against os.environ and a
missing one is REPORTED on stderr. Reported, not fatal: one dead hub should not stop a mission
that may not need it, but nobody should have to guess afterwards.

Usage: mcp-profile-config.py --profile <name> --out <file> [--config ~/.claude.json]
Exit 0 with a written file, or non-zero with nothing written and a reason on stderr.
"""
import argparse
import json
import os
import re
import sys

VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def env_refs(obj):
    """Every ${VAR} named anywhere in the server entry."""
    found = set()
    if isinstance(obj, dict):
        for v in obj.values():
            found |= env_refs(v)
    elif isinstance(obj, list):
        for v in obj:
            found |= env_refs(v)
    elif isinstance(obj, str):
        found |= set(VAR.findall(obj))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--config", default=os.path.expanduser("~/.claude.json"))
    a = ap.parse_args()

    try:
        with open(a.config, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception as e:
        print("mcp-profile-config: cannot read %s: %s" % (a.config, e), file=sys.stderr)
        return 2

    servers = cfg.get("mcpServers") or {}
    if not servers:
        print("mcp-profile-config: no mcpServers in %s" % a.config, file=sys.stderr)
        return 3

    keep = {n: s for n, s in servers.items() if n.startswith(a.profile)}
    if not keep:
        # ⚠️ REFUSE rather than write an empty config. An empty {"mcpServers":{}} with
        # --strict-mcp-config is indistinguishable at runtime from the bug this script exists
        # to fix, and it would look like the fix was applied.
        print("mcp-profile-config: no hub in %s starts with %r (have: %s)"
              % (a.config, a.profile, ", ".join(sorted(servers))), file=sys.stderr)
        return 4

    missing = {}
    for n, s in keep.items():
        gone = sorted(v for v in env_refs(s) if not os.environ.get(v))
        if gone:
            missing[n] = gone
    for n, gone in sorted(missing.items()):
        print("mcp-profile-config: WARN hub %r references unset env var(s): %s — it will be "
              "configured but every call will fail auth" % (n, ", ".join(gone)),
              file=sys.stderr)

    # ⛔ REFUSE to write a secret-bearing file into anything git tracks. See the module
    # docstring: these values are literal tokens on at least one machine in this estate.
    outdir = os.path.dirname(os.path.abspath(a.out)) or "."
    probe = outdir
    while True:
        if os.path.isdir(os.path.join(probe, ".git")):
            print("mcp-profile-config: REFUSING — %s is inside the git work tree at %s, and "
                  "this file may hold literal bearer tokens. Write it to a private temp "
                  "directory instead." % (a.out, probe), file=sys.stderr)
            return 5
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent

    tmp = a.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"mcpServers": keep}, fh, indent=2)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, a.out)
    print("mcp-profile-config: %d hub(s) for profile %r -> %s (%s)"
          % (len(keep), a.profile, a.out, ", ".join(sorted(keep))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
