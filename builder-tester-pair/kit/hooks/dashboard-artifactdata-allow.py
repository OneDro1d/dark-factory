#!/usr/bin/env python3
"""dashboard-artifactdata-allow.py — PreToolUse(ArtifactData): auto-approve ONLY the live dashboard's snapshot writes.

WHY: the builder pushes a status snapshot to the pair's live dashboard page (pair.yaml dashboard.artifact_url)
every tick. In auto permission mode with nobody at the keyboard, that ArtifactData call can be denied and the
page silently goes stale. This hook allows exactly that one write and nothing else.

ALLOWS (permissionDecision "allow"): ArtifactData calls whose `url` is dashboard.artifact_url, with no `as_level`,
whose action is get/list/query on the `snapshots` collection — and, ONLY in the builder's workspace (role by hostname),
set/delete on `snapshots` or a `batch` whose every write is a set/delete on `snapshots`. The builder is the one
writer; the tester (or an unknown host) gets reads only, and its writes go through the normal permission flow.
EVERYTHING ELSE gets no decision from this hook (it prints nothing) and goes through the normal permission flow:
another artifact, another collection, update/str_replace, `as_level`, an empty dashboard.artifact_url, no pair.yaml.

Who may write is enforced by the page itself: give its database a rule that only the owner writes (e.g.
{"path": "", "write": "admin"}); viewers can then read snapshots but not write them.

  python3 dashboard-artifactdata-allow.py --selftest
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

COLLECTION = "snapshots"
READS = {"get", "list", "query"}
WRITES = {"set", "delete", "batch"}


def dashboard():
    """(dashboard.artifact_url, this host's role); ("", "unknown") when pair.yaml cannot load."""
    try:
        import pairconf
        import socket
        cfg = pairconf.load()
        host = socket.gethostname()
        if os.environ.get("PAIR_GUARD_TEST_HOST") and str(cfg.get("_path", "")).startswith("/tmp/"):
            host = os.environ["PAIR_GUARD_TEST_HOST"]          # self-test only: a throw-away pair.yaml under /tmp
        url = str(pairconf.get(cfg, "dashboard.artifact_url", "") or "").strip().rstrip("/")
        return url, pairconf.role(cfg, host=host)
    except BaseException:
        return "", "unknown"


def allowed(ti, url, role="builder"):
    if not url or str(ti.get("url", "")).strip().rstrip("/") != url or ti.get("as_level"):
        return False
    action = ti.get("action")
    if action not in READS and not (action in WRITES and role == "builder"):
        return False
    if action == "batch":
        writes = ti.get("writes") or []
        return bool(writes) and all(isinstance(w, dict) and w.get("collection") == COLLECTION
                                    and w.get("op") in ("set", "delete") for w in writes)
    return ti.get("collection") == COLLECTION


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        return
    if event.get("tool_name") != "ArtifactData":
        return
    if not allowed(event.get("tool_input") or {}, *dashboard()):
        return
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "live dashboard snapshots (pair.yaml dashboard.artifact_url)",
    }}))


def selftest():
    import subprocess
    import tempfile
    url = "https://claude.ai/artifact/TESTdashboard123"
    tmp = tempfile.mkdtemp(prefix="dash-allow-")
    with_url = os.path.join(tmp, "with.yaml")
    no_url = os.path.join(tmp, "without.yaml")
    hosts = {"builder": {"name": "Forge", "host": "bt-builder"}, "tester": {"name": "Sentinel", "host": "bt-tester"}}
    with open(with_url, "w") as f:
        json.dump(dict(hosts, dashboard={"artifact_url": url + "/"}), f)
    with open(no_url, "w") as f:
        json.dump({"dashboard": {"artifact_url": ""}}, f)
    A = lambda **ti: {"tool_name": "ArtifactData", "tool_input": ti}
    cases = [  # (want allow, pair.yaml, event[, host]) — host defaults to the builder's
        (True, with_url, A(url=url, action="set", collection="snapshots", doc_id="latest", data={})),
        (False, with_url, A(url=url, action="set", collection="snapshots", doc_id="latest", data={}), "bt-tester"),
        (False, with_url, A(url=url, action="delete", collection="snapshots", doc_id="x"), "bt-tester"),
        (False, with_url, A(url=url, action="batch", writes=[{"op": "set", "collection": "snapshots"}]), "bt-tester"),
        (False, with_url, A(url=url, action="set", collection="snapshots", doc_id="latest"), "some-other-host"),
        (True, with_url, A(url=url, action="list", collection="snapshots"), "bt-tester"),
        (True, with_url, A(url=url + "/", action="delete", collection="snapshots", doc_id="x")),
        (True, with_url, A(url=url, action="list", collection="snapshots")),
        (True, with_url, A(url=url, action="batch", writes=[{"op": "set", "collection": "snapshots", "doc_id": "a"},
                                                           {"op": "delete", "collection": "snapshots", "doc_id": "b"}])),
        (False, with_url, A(url=url, action="set", collection="profiles", doc_id="x")),
        (False, with_url, A(url=url, action="update", collection="snapshots", doc_id="x")),
        (False, with_url, A(url=url, action="set", collection="snapshots", as_level="admin")),
        (False, with_url, A(url=url, action="batch", writes=[{"op": "set", "collection": "snapshots"},
                                                            {"op": "set", "collection": "profiles"}])),
        (False, with_url, A(url=url, action="batch", writes=[])),
        (False, with_url, A(url="https://claude.ai/artifact/OTHER", action="set", collection="snapshots")),
        (False, with_url, A(url=url + "x", action="set", collection="snapshots")),
        (False, with_url, {"tool_name": "Bash", "tool_input": {"command": "echo"}}),
        (False, no_url, A(url="", action="set", collection="snapshots")),
        (False, no_url, A(url=url, action="set", collection="snapshots")),
        (False, os.path.join(tmp, "missing.yaml"), A(url=url, action="set", collection="snapshots")),
    ]
    bad = 0
    for want, cfg, ev, *host in cases:
        env = dict(os.environ, PAIR_CONFIG=cfg, PAIR_GUARD_TEST_HOST=(host or ["bt-builder"])[0])
        out = subprocess.run([sys.executable, os.path.realpath(__file__)], input=json.dumps(ev), text=True,
                             capture_output=True, env=env).stdout
        got = '"allow"' in out
        bad += got != want
        ti = ev.get("tool_input", {})
        print("PASS" if got == want else "FAIL", "allow" if want else "pass-through",
              ev["tool_name"], ti.get("action", ""), ti.get("collection", ""), os.path.basename(cfg),
              (host or ["bt-builder"])[0])
    print("ALL PASS" if not bad else f"{bad} FAILED")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    main()
