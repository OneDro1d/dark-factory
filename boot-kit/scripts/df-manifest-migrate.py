#!/usr/bin/env python3
"""df-manifest-migrate — make a notepad's repos.manifest.json machine-neutral.

THE PROBLEM
-----------
Manifests recorded WHERE a repo sits. A location is a per-machine fact, so a manifest that
carries one is correct on the machine it was written on and wrong everywhere else —
"a machine-shaped constant in a file every machine reads is a lie on all but one of them."
Surveyed once across a fleet of notepads: the large majority still carried one machine's
absolute home-directory paths baked in.

THE FIX
-------
Store IDENTITY, derive location. A repo is `owner/repo`; where it sits is resolved per
machine from the instance lockfile (`codeRoot` + `codeLayout`) or, failing that, by
searching worktrees for a matching origin. Identity is stable; location is not.

So this rewrites each entry to:

    {"name": …, "remote": "owner/repo", "branch": …, "role": …, "note": …}

and DELETES `path` / `paths`. Deleting is the point, not a side effect: a stale path that
happens to exist on another machine is worse than no path at all, because it resolves
silently to the wrong tree. (A sibling directory can exist at exactly the recorded path
and simply not be the intended repo root — a smoke test once caught exactly that
near-miss.)

WHERE `remote` COMES FROM, strongest evidence first:
  1. the entry's own `remote`, normalised to owner/repo
  2. a local checkout's actual `git remote get-url origin`
  3. a UNIQUE name match across the surveyed orgs
  4. nothing — written as `null` with a TODO. df-preflight then reports `unknown`, never
     `ok` and never `drift`, because an unverifiable identity is not a finding about the
     world. Guessing here would defeat the entire exercise.

Usage:
  df-manifest-migrate.py --file <manifest> [--index <name-index.json>] [--apply]
Without --apply it prints the diff summary and writes nothing.
"""
import argparse
import json
import os
import re
import subprocess
import sys

RESOLUTION = [
    "1. If LOOM_REPO_<NAME> is set in the environment, use it. Explicit beats inferred.",
    "2. Otherwise the instance lockfile: probed.repos.<name>.path if an operator confirmed one.",
    "3. Otherwise codeRoot + codeLayout.<lane> + name, VERIFIED against .remote.",
    "4. Otherwise search every git worktree under codeRoot for a matching origin remote.",
    "5. If none resolves, ERROR naming the repo and what was tried. Never guess, never skip.",
    "NOTE: there is deliberately no `path` key. A path is a per-machine fact and does not",
    "belong in a file that every machine reads. `remote` is the identity -- directory",
    "names drift (a checkout gets cloned or renamed locally), origin remotes do not.",
]


def norm_remote(url):
    if not url:
        return ""
    u = url.strip()
    u = re.sub(r"^git@github\.com:", "", u)
    u = re.sub(r"^https?://(www\.)?github\.com/", "", u)
    u = re.sub(r"\.git$", "", u)
    return u.strip("/")


def entry_name(repo):
    n = repo.get("name")
    if n:
        return n
    rem = norm_remote(repo.get("remote"))
    if rem:
        return rem.split("/")[-1]
    for p in list((repo.get("paths") or {}).values()) + [repo.get("path") or ""]:
        if p:
            return os.path.basename(p.rstrip("/"))
    return ""


def origin_of(path):
    try:
        r = subprocess.run(["git", "-C", path, "remote", "get-url", "origin"],
                           capture_output=True, text=True, timeout=10)
        return norm_remote(r.stdout.strip()) if r.returncode == 0 else ""
    except Exception:
        return ""


def local_checkout(name, code_root):
    """A worktree under code_root whose basename matches. Depth-limited, like the probe."""
    if not name or not os.path.isdir(code_root):
        return ""
    base = os.path.abspath(code_root)
    depth0 = base.rstrip("/").count("/")
    for dirpath, dirnames, _ in os.walk(base):
        if dirpath.rstrip("/").count("/") - depth0 >= 3:
            dirnames[:] = []
        dirnames[:] = [d for d in dirnames if d not in
                       (".git", "node_modules", "vendor", ".venv", "__pycache__")]
        if os.path.basename(dirpath).lower() == name.lower() and \
           os.path.exists(os.path.join(dirpath, ".git")):
            return dirpath
    return ""


def migrate(manifest, index, code_root):
    """Returns (new_manifest, rows) where rows describe each entry's outcome."""
    out = dict(manifest)
    rows = []
    new_repos = []
    for repo in manifest.get("repos", []):
        name = entry_name(repo)
        had = norm_remote(repo.get("remote"))
        source = "manifest"
        remote = had

        if not remote:
            path = local_checkout(name, code_root)
            if path:
                remote = origin_of(path)
                source = "local checkout %s" % path
        if not remote:
            hits = index.get(name.lower(), [])
            if len(hits) == 1:
                remote, source = hits[0], "unique name match across surveyed orgs"
            elif len(hits) > 1:
                source = "AMBIGUOUS across orgs: %s" % ", ".join(hits)
            else:
                source = "no evidence anywhere"

        new = {"name": name, "remote": remote or None}
        for k in ("branch", "role", "note", "requires_df_context_store",
                  "has_df_context_store"):
            if k in repo:
                new[k] = repo[k]
        # Preserve any $-prefixed prose the author left behind: it is usually a caveat.
        for k, v in repo.items():
            if k.startswith("$"):
                new[k] = v
        if not remote:
            new["$TODO"] = ("remote unknown (%s). df-preflight will report this repo as "
                            "`unknown` -- identity cannot be verified -- until a remote is "
                            "filled in. It will NOT report it as missing." % source)

        dropped = [k for k in ("path", "paths") if k in repo]
        rows.append({"name": name, "remote": remote or None, "source": source,
                     "dropped": dropped})
        new_repos.append(new)

    out["repos"] = new_repos
    out["$resolution"] = RESOLUTION
    out["$migrated"] = ("2026-08-22 df-manifest-migrate: locations removed, identity kept. "
                        "See $resolution.")
    return out, rows


def resolve_code_root():
    """This machine's codeRoot, from the lockfile df-preflight would pick.

    FIXED once in practice. --code-root used to default to one specific workspace's
    literal path, baked into a tool that runs on several machines -- the exact
    "machine-shaped constant in a file every machine reads is a lie on all but one of
    them" this script's own docstring exists to argue against. On a machine where that
    directory does not exist, local_checkout() found nothing and every unresolved entry
    was reported as "no evidence anywhere". That reads as a fact about the world ("this
    repo has no discoverable remote") when it is only a fact about where the tool
    looked -- and it made repos that WERE resolvable, on the one machine that could
    resolve them, look permanently unclosable.

    One resolution rule for the whole engine: reuse df-preflight's, do not re-implement it.
    """
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "df_preflight", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     "df-preflight.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    lock_path, note = mod.find_lock()
    if not lock_path or not os.path.isfile(lock_path):
        return None, note or "no instance lockfile resolved"
    try:
        root = (json.load(open(lock_path)) or {}).get("codeRoot")
    except Exception as e:
        return None, "lockfile %s unreadable: %s" % (lock_path, e)
    if not root:
        return None, "%s declares no codeRoot" % lock_path
    return root, "codeRoot %s (from %s)" % (root, lock_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--index", help="JSON {name: [owner/repo, ...]} from the org survey")
    ap.add_argument("--code-root", default=None,
                    help="where this machine keeps code (default: from the instance lockfile)")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    if not a.code_root:
        a.code_root, why = resolve_code_root()
        if not a.code_root:
            sys.exit("cannot resolve codeRoot: %s. Pass --code-root explicitly -- guessing "
                     "one would report 'no evidence anywhere' for repos that are right "
                     "here." % why)
        print("   %s" % why)

    manifest = json.load(open(a.file))
    index = json.load(open(a.index)) if a.index else {}
    new, rows = migrate(manifest, index, a.code_root)

    unresolved = [r for r in rows if not r["remote"]]
    print("%s  (%d repos, %d unresolved)" % (a.file, len(rows), len(unresolved)))
    for r in rows:
        print("   %-34s %-45s %s%s" % (
            r["name"], r["remote"] or "** NO REMOTE **", r["source"],
            "  [dropped: %s]" % ",".join(r["dropped"]) if r["dropped"] else ""))

    if a.apply:
        with open(a.file, "w") as fh:
            json.dump(new, fh, indent=2)
            fh.write("\n")
        print("   -> written")
    return 1 if unresolved else 0


if __name__ == "__main__":
    sys.exit(main())
