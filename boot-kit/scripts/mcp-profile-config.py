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

⚠️ B24: THE NAME-PREFIX RULE IS A GUESS; A LOCKFILE ENTRY IS A FACT. Which servers in
~/.claude.json actually belong to a given estate is a MACHINE fact — recorded, when it is
known, as `mcp.profiles.<profile>` in the instance lockfile (see the starter-kit template for
the schema). When that entry exists this script uses it INSTEAD of the prefix guess:
  - `kind: "hubs"`      -> keep exactly the named servers; REFUSE (exit 2) if any is missing
                           from ~/.claude.json, naming it.
  - `kind: "connector"` -> a claude.ai CONNECTOR is not a `mcpServers` entry at all (measured:
                           it appears in NO file), so there is nothing to write into an
                           `--mcp-config` file. Instead this prints a machine-readable `PLAN`
                           line on STDOUT and writes NO file — df-worker reads that line and
                           scopes the connector by DENYING every other server's tools instead
                           of allow-listing one.
When no entry exists for the profile, this falls back to the ORIGINAL name-prefix rule below,
and says so once on stderr (INFO, not a warning: an undeclared profile is not a defect, only a
fact worth surfacing) -- `df-preflight --profile <p>` proposes the entry once it can see one.

Usage: mcp-profile-config.py --profile <name> --out <file>
           [--config ~/.claude.json] [--lock <instance-lockfile>]
Exit 0 with either a written file OR a printed PLAN line, or non-zero with neither and a
reason on stderr.
"""
import argparse
import json
import os
import platform
import re
import sys

VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
NAME_SANITISE = re.compile(r"[^A-Za-z0-9]")


def sanitise_name(name):
    """Every non-alphanumeric char in an MCP server name becomes `_`.

    Measured: a claude.ai CONNECTOR named "claude.ai ESO" exposes tools named
    `mcp__claude_ai_ESO__<upstream>__<tool>` -- this is that exact rule, applied wherever a
    server name has to become part of a tool-name prefix (a connector's own allow-prefix, or
    the deny-prefix for a hub-config server it must NOT reach).
    """
    return NAME_SANITISE.sub("_", name or "")


def resolve_machine_lock(kit_root=None):
    """Which instance lockfile describes THIS machine -- the same SMALL rule df-preflight's
    find_lock() applies, reimplemented rather than imported (this script stays standalone;
    see the module docstring's refusal-to-import precedent in df-worker).

    Root: any `*.lock.json` directly under the kit root. Instances: `instances/*/loom.lock.json`.
    A single candidate wins outright; several are disambiguated by a `machine` block matching
    this platform + home. Anything else (zero candidates, or an unresolved tie) returns None --
    the caller's fallback is the untouched, always-safe prefix rule, so "cannot tell" is never
    treated as "cannot proceed".
    """
    # kit_root defaults to two levels above THIS file -- right in an instance whose engine
    # is materialised into <instance>/boot-kit/scripts/. WRONG when this file runs from a
    # VENDORED Tier 1 (<instance>/vendor/dark-factory/boot-kit/scripts/): two levels up is
    # vendor/dark-factory, which holds no lockfile, so lookup returned None and the prefix
    # rule silently took over -- measured 2026-09-06 on the first connector-mode dispatch
    # from a kit's vendored shim. df-worker therefore passes --kit-root (the directory
    # df-mission on PATH really lives under); the default stays for direct invocations.
    if not kit_root:
        kit_root = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", ".."))
    cands = []
    if os.path.isdir(kit_root):
        for n in sorted(os.listdir(kit_root)):
            p = os.path.join(kit_root, n)
            if n.endswith(".lock.json") and os.path.isfile(p):
                cands.append(p)
    inst_dir = os.path.join(kit_root, "instances")
    if os.path.isdir(inst_dir):
        for n in sorted(os.listdir(inst_dir)):
            p = os.path.join(inst_dir, n, "loom.lock.json")
            if os.path.isfile(p):
                cands.append(p)
    if not cands:
        return None
    if len(cands) == 1:
        return cands[0]

    me = {"platform": platform.system(), "home": os.path.expanduser("~")}
    matched = []
    for c in cands:
        try:
            with open(c, encoding="utf-8") as fh:
                m = (json.load(fh) or {}).get("machine") or {}
        except Exception:
            continue
        if m and all(m.get(k) == v for k, v in me.items()):
            matched.append(c)
    matched = narrow_by_identity(matched, _load_json_quiet)
    return matched[0] if len(matched) == 1 else None


def _load_json_quiet(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def narrow_by_identity(matched, load):
    """Several records claim this platform + home. MEASURED 2026-09-08 on the homelab Coder:
    two instance records of one kit (homelab, poland) both say {Linux, /home/coder} — the
    machine block is deliberately not keyed on hostname, because a Coder pod is renamed on
    every restart — so the tie could not be broken and the worker chain refused to launch,
    although each record already carried the discriminator identify.sh measured into it:
    install.identity.workspace (CODER_WORKSPACE_NAME) and install.identity.deploymentId (from
    GET <CODER_AGENT_URL>/api/v2/buildinfo — the URL itself is NOT unique, the id is).

    Narrow by the workspace name from the environment; if that still ties (one workspace
    name on two deployments — the ESO estate's shape), ask the control plane for its
    deployment id, best effort, 3 s. Learn nothing → return the list unchanged, so "cannot
    tell" stays visible to the caller. Same code, by design, as df-preflight.find_lock().
    """
    if len(matched) < 2:
        return matched
    ws = os.environ.get("CODER_WORKSPACE_NAME", "").strip()
    if not ws:
        return matched

    def ident(c):
        try:
            return ((load(c) or {}).get("install") or {}).get("identity") or {}
        except Exception:
            return {}

    by_ws = [c for c in matched if ident(c).get("workspace") == ws]
    if len(by_ws) == 1:
        return by_ws
    if not by_ws:
        return matched
    url = os.environ.get("CODER_AGENT_URL", "").strip().rstrip("/")
    if not url:
        return by_ws
    try:
        import urllib.request
        # TLS verified, on purpose: a control plane whose certificate does not verify teaches
        # this resolver nothing, and "nothing learned" is the safe answer (the tie stays).
        with urllib.request.urlopen(url + "/api/v2/buildinfo", timeout=3) as r:
            dep = (json.loads(r.read().decode("utf-8", "replace")) or {}).get("deployment_id", "")
    except Exception:
        return by_ws
    by_dep = [c for c in by_ws if dep and ident(c).get("deploymentId") == dep]
    return by_dep if len(by_dep) == 1 else by_ws


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


def write_config(keep, out_path, profile, empty_detail):
    """Shared tail: env-var warnings, the git-worktree refusal, then the atomic 0600 write.

    Used by BOTH the mcp.profiles-declared `hubs` path and the fallback prefix-rule path --
    one place that knows how to safely materialise a set of servers, so the secret-handling
    rules (never printed, 0600, refused inside a git tree) cannot drift between the two.
    """
    if not keep:
        # ⚠️ REFUSE rather than write an empty config. An empty {"mcpServers":{}} with
        # --strict-mcp-config is indistinguishable at runtime from the bug this script exists
        # to fix, and it would look like the fix was applied.
        print("mcp-profile-config: no hub to configure for profile %r (%s)"
              % (profile, empty_detail), file=sys.stderr)
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
    outdir = os.path.dirname(os.path.abspath(out_path)) or "."
    probe = outdir
    while True:
        if os.path.isdir(os.path.join(probe, ".git")):
            print("mcp-profile-config: REFUSING — %s is inside the git work tree at %s, and "
                  "this file may hold literal bearer tokens. Write it to a private temp "
                  "directory instead." % (out_path, probe), file=sys.stderr)
            return 5
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent

    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"mcpServers": keep}, fh, indent=2)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, out_path)
    print("mcp-profile-config: %d hub(s) for profile %r -> %s (%s)"
          % (len(keep), profile, out_path, ", ".join(sorted(keep))))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--config", default=os.path.expanduser("~/.claude.json"))
    ap.add_argument("--lock", default=None,
                     help="instance lockfile to read mcp.profiles from (else auto-resolved "
                          "the same way df-preflight resolves the machine's lockfile)")
    ap.add_argument("--kit-root", default=None,
                     help="instance root to discover the machine lockfile under (default: two "
                          "levels above this file -- wrong when this file is the VENDORED copy; "
                          "df-worker passes the root df-mission on PATH lives under)")
    a = ap.parse_args()

    # ⛔ ORDER MATTERS, and it was wrong until 2026-09-08. This used to refuse "no mcpServers"
    # HERE, before the lockfile was even read — so on a machine whose ~/.claude.json holds no
    # mcpServers (the connector estate's normal shape: credentials come from shared storage,
    # and the record says never to copy a bearer token into that file to satisfy a check) a
    # `kind: connector` profile could never be reached, LOOM_LOCK or not. Measured on the
    # homelab Coder: df-worker refused "no MCP config for profile 'onedroid'" while the record
    # declared exactly that profile. A connector needs no mcpServers at all; only `hubs` and
    # the name-prefix fallback do. So: read the config leniently, resolve the profile, and
    # refuse for want of servers only where servers are what the shape needs.
    cfg_err = None
    cfg = {}
    try:
        with open(a.config, encoding="utf-8") as fh:
            cfg = json.load(fh) or {}
    except Exception as e:
        cfg_err = "%s" % e
    servers = cfg.get("mcpServers") or {}

    def need_servers():
        """Refuse, with the same exit codes as before, for a shape that needs mcpServers."""
        if cfg_err is not None:
            print("mcp-profile-config: cannot read %s: %s" % (a.config, cfg_err), file=sys.stderr)
            return 2
        if not servers:
            print("mcp-profile-config: no mcpServers in %s" % a.config, file=sys.stderr)
            return 3
        return 0

    # LOOM_LOCK sits between the explicit flag and the path-derived guess. It is how
    # df-preflight and df-mission are told which instance this is on a VENDORED kit (START-HERE
    # D-5), and this script ignoring it was measured 2026-09-08 on the eso laptop: with the
    # variable exported, `--profile eso` still exited 4 "mcp.profiles is undeclared" because
    # resolve_machine_lock() looked two levels above the vendored engine and found no lockfile.
    # The supervisor never passes --lock, so every supervised mission on a vendored kit ran with
    # NO MCP plan -- and said so only in a WARN line the operator has to notice.
    lock_path = a.lock or os.environ.get("LOOM_LOCK") or resolve_machine_lock(a.kit_root)
    lock = {}
    if lock_path:
        try:
            with open(lock_path, encoding="utf-8") as fh:
                lock = json.load(fh) or {}
        except Exception as e:
            print("mcp-profile-config: cannot read --lock %s: %s" % (lock_path, e), file=sys.stderr)
            return 2

    mcp_profiles = (lock.get("mcp") or {}).get("profiles") or {}
    prof_entry = mcp_profiles.get(a.profile)

    if prof_entry:
        kind = prof_entry.get("kind")
        want = prof_entry.get("servers") or []
        if kind == "hubs":
            rc = need_servers()
            if rc:
                return rc
            missing_hubs = [n for n in want if n not in servers]
            if missing_hubs:
                print("mcp-profile-config: mcp.profiles.%s (hubs) names server(s) missing "
                      "from %s mcpServers: %s" % (a.profile, a.config, ", ".join(missing_hubs)),
                      file=sys.stderr)
                return 2
            keep = {n: servers[n] for n in want}
            return write_config(keep, a.out, a.profile,
                                "mcp.profiles.%s (hubs) declares no servers" % a.profile)
        if kind == "connector":
            name = want[0] if want else None
            if not name:
                print("mcp-profile-config: mcp.profiles.%s (connector) declares no server "
                      "name in `servers`" % a.profile, file=sys.stderr)
                return 2
            # ⛔ A CLAUDE.AI CONNECTOR IS NOT AN --mcp-config ENTRY. It appears in NO file
            # (measured: mcpServers holds only file-based hubs), so there is nothing here to
            # allow-list into a config. Scoping instead means DENYING every OTHER server's
            # tools: every hub-config server present on this machine, plus any plugin-shipped
            # tool namespace, so only the target connector's own tools remain reachable.
            disallow = ["mcp__%s__*" % sanitise_name(n) for n in sorted(servers)]
            disallow.append("mcp__plugin_*")
            plan = {
                "mode": "connector",
                "name": name,
                "allowPrefix": "mcp__%s__" % sanitise_name(name),
                "disallow": disallow,
            }
            print("PLAN " + json.dumps(plan))
            return 0
        print("mcp-profile-config: mcp.profiles.%s has unrecognised kind %r (expected "
              "'hubs' or 'connector')" % (a.profile, kind), file=sys.stderr)
        return 2

    # ---- no declared entry: the ORIGINAL name-prefix rule, informed rather than silent ----
    rc = need_servers()
    if rc:
        return rc
    print("mcp-profile-config: INFO mcp.profiles is undeclared for profile %r — using the "
          "name-prefix rule (run df-preflight --profile %s to get a proposal)"
          % (a.profile, a.profile), file=sys.stderr)
    keep = {n: s for n, s in servers.items() if n.startswith(a.profile)}
    return write_config(keep, a.out, a.profile,
                         "no hub in %s starts with %r (have: %s)"
                         % (a.config, a.profile, ", ".join(sorted(servers))))


if __name__ == "__main__":
    sys.exit(main())
