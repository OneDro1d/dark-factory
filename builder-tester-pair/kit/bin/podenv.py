#!/usr/bin/env python3
"""
podenv.py — the ONE sanctioned way to look at environment variables inside a pod. It never prints a value.

Why: masking cannot work. A DENY-list mask (*KEY*|*SECRET*|*PASSWORD*|*TOKEN*) prints `Db__Auth` (user AND
password) in full, because not every secret has "secret" in its name; a PREFIX grep (`^Mcp__`) prints
`Mcp__RouterBearerToken` in full, because a prefix selects a FAMILY and families contain credentials. You cannot
enumerate what is sensitive, so this tool reports only what answers the real questions — is it set, is it the
same in every pod, is it still a placeholder — and never the value itself.

Usage:
  podenv.py <ns> <var> [<var>...]        per pod: each var's length, a same-value group (A, B, …) and a
                                          placeholder flag — never the value
  podenv.py --all-ns <var> [<var>...]    the same across pair.yaml repos[].sut_namespaces
  podenv.py --keys <ns> [<pod>]          the variable NAMES (and lengths) a pod's main process has
  podenv.py --selftest

Same-value groups are computed with a random key that lives only for this run, so they say "these pods agree"
without leaving anything (not even a hash) that could be matched against a guessed value later.
kubectl uses your normal environment (KUBECONFIG, in-cluster service account); nothing is overridden.
A FAILED kubectl query is reported as failed (exit 1), never as "no pods".
"""
import hashlib
import hmac
import os
import pathlib
import secrets
import shutil
import subprocess
import sys
import tempfile

# Known placeholder values. A variable still holding one of these is flagged `placeholder`; the value itself is
# still not printed (the flag answers the question).
PLACEHOLDERS = {"REPLACE_ME", "replace-me", "NOT_CONFIGURED", "changeme", "CHANGEME", "TODO", "placeholder",
                "PLACEHOLDER", "<placeholder>", "xxx", "XXX"}
_RUN_KEY = secrets.token_bytes(32)


def kube(args):
    return subprocess.run(["kubectl"] + args, capture_output=True, text=True, env=dict(os.environ))


def pods(ns):
    r = kube(["get", "pods", "-n", ns, "-o", "name", "--no-headers"])
    if r.returncode != 0:
        # A FAILED QUERY IS NOT AN EMPTY NAMESPACE. Reporting zero here is the exact defect k8s-ready.py prevents.
        print(f"  !! query FAILED for {ns} (kubectl exit {r.returncode}) — not the same as zero pods", file=sys.stderr)
        return None
    return [l.split("/", 1)[1] for l in r.stdout.split() if "/" in l]


class Groups:
    """Per variable name: equal values get the same letter, within this run only."""

    def __init__(self):
        self.seen = {}

    def label(self, name, value):
        tag = hmac.new(_RUN_KEY, value.encode(), hashlib.sha256).digest()
        m = self.seen.setdefault(name, {})
        if tag not in m:
            n = len(m)
            m[tag] = chr(ord("A") + n) if n < 26 else f"G{n}"
        return m[tag]


def describe(name, value, groups):
    if value == "":
        return f"{name} empty"
    flag = "  placeholder" if value.strip() in PLACEHOLDERS else ""
    return f"{name} len={len(value)} group={groups.label(name, value)}{flag}"


def namespaces_from_config():
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
    import pairconf
    cfg = pairconf.load()
    out = []
    for r in pairconf.apps(cfg).values():
        for ns in r.get("sut_namespaces") or []:
            if ns not in out:
                out.append(str(ns))
    return out


def env_of(ns, pod):
    """Name -> value of the pod's main process (in memory only, never printed). None if it cannot be read."""
    r = kube(["exec", "-n", ns, pod, "--", "cat", "/proc/1/environ"])
    if r.returncode == 0 and r.stdout:
        out = {}
        for item in r.stdout.split("\0"):
            if "=" in item:
                k, _, v = item.partition("=")
                out[k] = v
        return out
    return None


def keys(ns, pod=None):
    ps = [pod] if pod else pods(ns)
    if ps is None:
        return 1
    print(f"--- {ns} ({len(ps)} pod{'s' if len(ps) != 1 else ''}) — names and lengths only ---")
    rc = 0
    for p in ps:
        e = env_of(ns, p)
        if e is None:
            print(f"  {p}: could not read the environment (exec failed) — not the same as an empty one")
            rc = 1
            continue
        print(f"  {p}: {len(e)} variables")
        for k in sorted(e):
            v = e[k]
            print(f"    {k}  len={len(v)}" + ("  placeholder" if v.strip() in PLACEHOLDERS else ""))
    return rc


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 2
    if argv[0] == "--show":
        print("  REFUSED: podenv never prints a value. The length, same-value group and placeholder flag answer")
        print("  every question except 'what is the literal secret' — read that from its source of record if you must.")
        return 1
    if argv[0] == "--keys":
        if len(argv) not in (2, 3):
            print(__doc__)
            return 2
        return keys(argv[1], argv[2] if len(argv) == 3 else None)
    if len(argv) < 2:
        print(__doc__)
        return 2
    ns_list, names = [argv[0]], argv[1:]
    if argv[0] == "--all-ns":
        ns_list = namespaces_from_config()
        if not ns_list:
            print("  no namespaces: set repos[].sut_namespaces in pair.yaml, or name one namespace")
            return 2
    groups = Groups()
    rc = 0
    for ns in ns_list:
        ps = pods(ns)
        if ps is None:
            rc = 1
            continue
        print(f"--- {ns} ({len(ps)} pods) ---")
        hits = 0
        for p in ps:
            out = []
            for n in names:
                r = kube(["exec", "-n", ns, p, "--", "printenv", n])
                if r.returncode != 0:   # printenv exits 1 when the name is not set (or exec failed)
                    continue
                out.append(describe(n, r.stdout.rstrip("\n"), groups))
            if out:
                hits += 1
                print(f"  {p:<44} {'  '.join(out)}")
        if hits == 0:
            print("  (no pod in this namespace declares any of those names — a checked-and-empty result, the query ran)")
    return rc


def selftest():
    base = pathlib.Path(f"/tmp/claude-{os.getuid()}") if pathlib.Path(f"/tmp/claude-{os.getuid()}").is_dir() else pathlib.Path(tempfile.gettempdir())
    t = pathlib.Path(tempfile.mkdtemp(prefix="podenv-selftest-", dir=base))
    bad = 0
    # fake values, assembled at run time; the test asserts none of them is ever printed
    v1, v2 = "s3cr3t-" + "alpha-0001", "s3cr3t-" + "bravo-0002"
    fake = f"""#!/bin/sh
# fake kubectl for podenv --selftest
case "$*" in
  "get pods -n broken"*) echo "forbidden" >&2; exit 1;;
  "get pods -n empty"*) exit 0;;
  "get pods -n app"*) printf 'pod/web-1\\npod/web-2\\npod/web-3\\n';;
  *"web-1 -- printenv DB_PASS") echo '{v1}';;
  *"web-2 -- printenv DB_PASS") echo '{v1}';;
  *"web-3 -- printenv DB_PASS") echo '{v2}';;
  *"-- printenv API_KEY") echo 'REPLACE_ME';;
  *"-- printenv EMPTY_ONE") echo '';;
  *"web-1 -- cat /proc/1/environ") printf 'DB_PASS={v1}\\0HOME=/root\\0';;
  *"-- cat /proc/1/environ") exit 1;;
  *"-- printenv"*) exit 1;;
esac
"""
    (t / "kubectl").write_text(fake)
    (t / "kubectl").chmod(0o755)
    (t / "pair.yaml").write_text("project: {name: S, slug: s}\nowner: {name: O}\nbuilder: {name: B, host: h1}\n"
                                 f"tester: {{name: T, host: h2}}\npaths: {{shared_root: {t}}}\n"
                                 "repos:\n  - {app: api, sut_namespaces: [app, broken]}\n")

    def run(*a):
        env = dict(os.environ, PATH=f"{t}:{os.environ.get('PATH', '')}", PAIR_CONFIG=str(t / "pair.yaml"))
        r = subprocess.run([sys.executable, str(pathlib.Path(__file__).resolve()), *a], env=env, capture_output=True, text=True)
        return r, r.stdout + r.stderr

    def check(name, ok, detail=""):
        nonlocal bad
        bad += not ok
        print("PASS" if ok else "FAIL", name, "" if ok else "(output withheld: it may hold a fixture value)")

    try:
        r, out = run("app", "DB_PASS", "API_KEY", "EMPTY_ONE", "MISSING")
        lines = {l.split()[0]: l for l in out.splitlines() if l.startswith("  web-")}
        check("values never printed", v1 not in out and v2 not in out and "REPLACE_ME" not in out)
        check("lengths reported", f"DB_PASS len={len(v1)}" in out)
        check("same value -> same group, different -> different",
              "group=A" in lines.get("web-1", "") and "DB_PASS len=17 group=A" in lines.get("web-2", "")
              and "DB_PASS len=17 group=B" in lines.get("web-3", ""))
        check("placeholder flagged without its value", "API_KEY len=10 group=A  placeholder" in out)
        check("empty value says empty", "EMPTY_ONE empty" in out)
        check("unset name left out", "MISSING" not in out and r.returncode == 0)
        r, out = run("broken", "DB_PASS")
        check("failed query is a failure, not zero pods", r.returncode == 1 and "query FAILED" in out and "0 pods" not in out)
        r, out = run("empty", "DB_PASS")
        check("empty namespace is a checked-and-empty result", r.returncode == 0 and "checked-and-empty" in out)
        r, out = run("--all-ns", "DB_PASS")
        check("--all-ns sweeps repos[].sut_namespaces and keeps the failure", "--- app (3 pods)" in out and "FAILED for broken" in out
              and r.returncode == 1 and v1 not in out)
        r, out = run("--keys", "app", "web-1")
        check("--keys: names and lengths, never values", "DB_PASS  len=17" in out and "HOME  len=5" in out
              and v1 not in out and "/root" not in out)
        r, out = run("--keys", "app", "web-2")
        check("--keys: unreadable env is a failure, not empty", r.returncode == 1 and "could not read" in out)
        r, out = run("--show", "app", "DB_PASS")
        check("--show refused, prints nothing of the value", r.returncode == 1 and "REFUSED" in out and v1 not in out)
    finally:
        shutil.rmtree(t, ignore_errors=True)
    print("ALL PASS" if not bad else f"{bad} FAILED")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        sys.exit(selftest())
    sys.exit(main(sys.argv[1:]))
