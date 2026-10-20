#!/usr/bin/env python3
"""
k8s-ready.py — the ONE correct way to count pod readiness.

Usage:  kubectl -n NS get pods --no-headers | k8s-ready.py NS
        k8s-ready.py NS1 NS2 ...          (runs kubectl itself, with your normal environment)
        k8s-ready.py --all-ns             (pair.yaml repos[].sut_namespaces)
        k8s-ready.py --selftest

Exists because readiness was once counted with:

    awk '$2 ~ /^([0-9]+)\\/\\1$/ && $3=="Running"'

POSIX awk has NO regex backreferences, so `\\1` is a literal '1'. The pattern matched almost nothing and reported
"Ready=0/14" for a namespace where all 14 pods were 1/1 Running — a total outage that did not exist, nearly
broadcast.

THE GENERAL LESSON: a check that can never go GREEN is exactly as worthless as one that can never go RED. Both are
decorative. This tool therefore SELF-TESTS: it asserts on known inputs that it reports both a green and a red, so
a silently-broken matcher cannot survive.

  ready     = every container ready (a==b, a>0) AND phase Running
  completed = Job pods (phase Completed/Succeeded) — counted SEPARATELY, never as failures
  exit 1 if anything is genuinely not ready, if the query FAILED, or if it returned no pods at all
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


def classify(line):
    """-> ('ready'|'completed'|'bad', text)"""
    f = line.split()
    if len(f) < 3:
        return None, line
    ready, phase = f[1], f[2]
    if phase in ("Completed", "Succeeded"):
        return "completed", line
    if "/" not in ready:
        return "bad", line
    a, _, b = ready.partition("/")
    if a == b and a != "0" and phase == "Running":
        return "ready", line
    return "bad", line


def report(ns, text):
    ready = comp = 0
    bad = []
    for line in text.splitlines():
        k, t = classify(line)
        if k == "ready":
            ready += 1
        elif k == "completed":
            comp += 1
        elif k == "bad":
            bad.append(t.rstrip())
    tot = ready + len(bad)
    if tot == 0 and comp == 0:
        print(f"  {ns}: NO PODS RETURNED — that is an empty result, not a healthy one.")
        return 1
    print(f"  {ns}: {ready}/{tot} ready" + (f"  (+{comp} completed jobs)" if comp else ""))
    for b in bad:
        print(f"     NOT READY: {b}")
    return 1 if bad else 0


def run(nss):
    rc = 0
    for ns in nss:
        # The caller's environment as is (KUBECONFIG, in-cluster service account). If auth fails, that is reported
        # as a FAILED QUERY, never as zero pods — do not "fix" that by defaulting to 0.
        p = subprocess.run(["kubectl", "-n", ns, "get", "pods", "--no-headers"], capture_output=True, text=True,
                           env=dict(os.environ))
        if p.returncode != 0:
            print(f"  {ns}: QUERY FAILED — {p.stderr.strip()[:120]}")
            print("     (a failed query is NOT zero pods; do not read it as healthy)")
            rc = 1
            continue
        rc |= report(ns, p.stdout)
    return rc


def namespaces_from_config():
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
    import pairconf
    out = []
    for r in pairconf.apps(pairconf.load()).values():
        for ns in r.get("sut_namespaces") or []:
            if str(ns) not in out:
                out.append(str(ns))
    return out


def selftest():
    cases = [
        ("web-1  1/1  Running  0  1d", "ready"),
        ("api-2  3/3  Running  0  1d", "ready"),
        ("job-3  0/1  Completed  0  1d", "completed"),
        ("job-4  0/1  Succeeded  0  1d", "completed"),
        ("bad-4  1/2  Running  0  1d", "bad"),
        ("bad-5  0/1  CrashLoopBackOff  3  1d", "bad"),
        ("bad-6  1/1  Terminating  0  1d", "bad"),
        ("bad-7  0/0  Running  0  1d", "bad"),
        ("bad-8  10/11  Running  0  1d", "bad"),
        ("ok-9  11/11  Running  0  1d", "ready"),
        ("bad-10  1/1  Pending  0  1d", "bad"),
    ]
    ok = True

    def fail(msg):
        nonlocal ok
        ok = False
        print(f"  SELFTEST FAIL: {msg}")

    for text, want in cases:
        got, _ = classify(text)
        if got != want:
            fail(f"{text!r} -> {got}, want {want}")
    # the point of the exercise: the matcher must produce BOTH verdicts
    if not {"ready", "bad"} <= {classify(t)[0] for t, _ in cases}:
        fail("matcher never produced both ready AND bad — a check that cannot go both ways proves nothing.")
    # report(): green, red, jobs-only, empty
    import contextlib, io
    def rep(text):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = report("ns", text)
        return rc, buf.getvalue()
    rc, out = rep("a 1/1 Running 0 1d\nb 2/2 Running 0 1d\n")
    if rc != 0 or "2/2 ready" not in out:
        fail(f"all-ready namespace not GREEN: {out!r}")
    rc, out = rep("a 1/1 Running 0 1d\nb 0/1 CrashLoopBackOff 0 1d\n")
    if rc != 1 or "1/2 ready" not in out or "NOT READY: b" not in out:
        fail(f"broken pod not RED: {out!r}")
    rc, out = rep("j 0/1 Completed 0 1d\n")
    if rc != 0 or "+1 completed" not in out:
        fail(f"finished job counted as a failure: {out!r}")
    rc, out = rep("")
    if rc != 1 or "NO PODS RETURNED" not in out:
        fail(f"empty result read as healthy: {out!r}")
    # run(): a failed kubectl query is a failure, never zero pods (fake kubectl on PATH)
    base = pathlib.Path(f"/tmp/claude-{os.getuid()}") if pathlib.Path(f"/tmp/claude-{os.getuid()}").is_dir() else pathlib.Path(tempfile.gettempdir())
    t = pathlib.Path(tempfile.mkdtemp(prefix="k8s-ready-selftest-", dir=base))
    try:
        (t / "kubectl").write_text('#!/bin/sh\ncase "$*" in\n  "-n good "*) echo "w 1/1 Running 0 1d";;\n'
                                   '  *) echo "Unauthorized" >&2; exit 1;;\nesac\n')
        (t / "kubectl").chmod(0o755)
        env = dict(os.environ, PATH=f"{t}:{os.environ.get('PATH', '')}")
        me = str(pathlib.Path(__file__).resolve())
        r = subprocess.run([sys.executable, me, "good"], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if r.returncode != 0 or "1/1 ready" not in r.stdout:
            fail(f"run() GREEN case: {r.stdout!r}")
        r = subprocess.run([sys.executable, me, "good", "denied"], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if r.returncode != 1 or "denied: QUERY FAILED" not in r.stdout or "0/0" in r.stdout:
            fail(f"run() failed query not reported as a failure: {r.stdout!r}")
    finally:
        shutil.rmtree(t, ignore_errors=True)
    print("  ALL PASS" if ok else "  FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--selftest":
        sys.exit(selftest())
    if a == ["--all-ns"]:
        a = namespaces_from_config()
        if not a:
            sys.exit("no namespaces: set repos[].sut_namespaces in pair.yaml, or name them")
        sys.exit(run(a))
    if not sys.stdin.isatty() and len(a) <= 1:
        data = sys.stdin.read()
        if data or not a:
            sys.exit(report(a[0] if a else "(stdin)", data))
    if not a:
        print(__doc__)
        sys.exit(2)
    sys.exit(run(a))
