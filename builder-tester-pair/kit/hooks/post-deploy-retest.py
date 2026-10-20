#!/usr/bin/env python3
"""post-deploy-retest.py — PostToolUse(Bash): after a cluster write to one of the pair's apps, remind the agent
that the deploy is not done until the tester's live retest passes.

WHY: a builder that deploys and then checks its own work with its own tests is grading itself. Its suites can be
green while its own test residue has broken a live endpoint. The tester's live retest — checks the builder never
saw, run by the agent that wrote them — is the independent check. This hook makes the next step impossible to
forget: record the deploy on the hand-over (`handoff deployed <id>`), which sends it to the tester for the live
retest.

WHAT IT DOES: never blocks. Adds context when a Bash step MUTATES a cluster —
  kubectl/oc/k apply, create, replace, patch, scale, autoscale, expose, debug, set image|env|resources,
  rollout restart|undo, edit, delete, label, annotate; `helm upgrade|install|uninstall|rollback`;
  `kustomize build X | kubectl apply -f -` and `kubectl kustomize X | kubectl apply -f -`;
  `kubectl get … -o yaml | sed … | kubectl apply -f -` (namespace taken from an earlier pipe segment)
— and that write touches the pair's apps, from pair.yaml:
  namespaces: repos[].infra + repos[].sut_namespaces  (with -n X, -n=X, --namespace X|=X, before or after the verb)
  apps:       repos[].app + repos[].services           (deploy/<name>, deployment <name>, a helm release name, or a
                                                         word in a kustomize/-k overlay path)
When pair.yaml lists no namespaces and no services it fires on every cluster write.
Quiet on reads (get, describe, logs, diff, rollout status, auth can-i), on commit messages and heredocs, and on
text about a command (echo, printf, grep, rg, cat <<). No pair.yaml = silent.

  python3 post-deploy-retest.py --selftest
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

VERB = (r"\b(apply|create|replace|patch|scale|autoscale|expose|debug|set\s+(image|env|resources)"
        r"|rollout\s+(restart|undo)|edit|delete|label|annotate)\b")
READ = r"\b(?:kubectl|oc|k)\b[^|]*\b(diff|get|describe|logs|rollout\s+status|auth)\b"
KTOOL = r"\b(?:kubectl|oc)\b|(?:^|\s)k\s"
NS_ANY = re.compile(r"(?:\s-n[=\s]*|--namespace[=\s])([a-z0-9][a-z0-9.-]*)")


def load_targets():
    try:
        import pairconf
        cfg = pairconf.load()
    except BaseException:
        return None
    namespaces, services, apps = set(), set(), set()
    for r in pairconf.get(cfg, "repos", []) or []:
        if not isinstance(r, dict):
            continue
        namespaces.update(str(x) for x in (r.get("infra") or []) + (r.get("sut_namespaces") or []) if x)
        services.update(str(x) for x in (r.get("services") or []) if x)
        if r.get("app"):
            apps.add(str(r["app"]))
    tester = pairconf.get(cfg, "tester.name", "the tester")
    return {"namespaces": namespaces, "names": services | apps, "tester": tester,
            "match_all": not namespaces and not services}


def strip_text(cmd):
    cmd = re.sub(r"(-m|--message)\s+(\"[^\"]*\"|'[^']*')", "", cmd)
    return re.sub(r"<<-?\s*['\"]?(\w+)['\"]?\n.*?\n\1\b", "<<HEREDOC", cmd, flags=re.S)


def name_in(text, names):
    hits = set()
    for n in names:
        if re.search(r"(?:deploy(?:ment)?s?(?:\.apps)?[/\s]+|statefulsets?[/\s]+|daemonsets?[/\s]+|"
                     r"cronjobs?[/\s]+|jobs?[/\s]+|svc[/\s]+|services?[/\s]+)" + re.escape(n) + r"\b", text):
            hits.add(n)
    return hits


def path_names(path, names):
    parts = set(re.split(r"[/_.\s]+", path))
    return {n for n in names if n in parts or any(p.startswith(n + "-") or p.endswith("-" + n) for p in parts)}


def detect(cmd, t):
    """Return a sorted list of what was touched ('namespace X', 'app Y'), or [] when quiet."""
    cmd = strip_text(cmd)
    ns_ok = (lambda ns: True) if t["match_all"] else (lambda ns: ns in t["namespaces"])
    touched = set()
    for step in re.split(r";|&&|\|\||\n", cmd):
        if re.match(r"^\s*(echo|printf|grep|rg|cat\s+<<|#)", step):
            continue                                       # text about a command is not the command
        m = re.search(r"\b(kustomize\s+build|kubectl\s+kustomize)\s+(\S+)[^|]*\|\s*(?:kubectl|oc)\b[^|]*\bapply\b", step)
        if m:
            hits = path_names(m.group(2), t["names"])
            ns = {n for n in NS_ANY.findall(step) if ns_ok(n)}
            if t["match_all"] or hits or ns:
                touched.update({f"app {h}" for h in hits} | {f"namespace {n}" for n in ns} or {f"overlay {m.group(2)}"})
            continue
        h = re.search(r"\bhelm\s+(upgrade|install|uninstall|rollback)\b(.*)", step)
        if h:
            ns = {n for n in NS_ANY.findall(step) if ns_ok(n)}
            words = set(re.findall(r"[A-Za-z0-9][\w.-]*", h.group(2)))
            rel = {n for n in t["names"] if n in words}
            if t["match_all"] or ns or rel:
                touched.update({f"namespace {n}" for n in ns} | {f"app {r}" for r in rel} or {"helm release"})
        for seg in step.split("|"):
            if not (re.search(KTOOL, seg) and re.search(VERB, seg)) or re.search(READ, seg):
                continue
            ns_found = NS_ANY.findall(seg) or NS_ANY.findall(step)   # `get -n X -o yaml | sed | apply -f -`
            ns = {n for n in ns_found if ns_ok(n)}
            apps = name_in(seg, t["names"])
            k = re.search(r"\s-k\s+(\S+)|--kustomize[=\s]+(\S+)", seg)
            if k:
                apps |= path_names(k.group(1) or k.group(2), t["names"])
            if ns or apps or (t["match_all"] and not ns_found):
                touched.update({f"namespace {n}" for n in ns} | {f"app {a}" for a in apps} or {"the cluster"})
    return sorted(touched)


def message(where, tester):
    return (
        f"## Deploy not done yet — {tester}'s live retest is the check\n"
        f"You changed {where}. Your own tests passing is the builder grading itself.\n"
        "Before calling it done:\n"
        "1. Wait for the rollout to finish (`kubectl rollout status`, read-only) — a retest against a half-rolled\n"
        "   Deployment is noise.\n"
        "2. Record it on the hand-over: `handoff deployed <id> --approval appr-…` (or `--by-owner \"…\"` when the owner\n"
        f"   ran it). That sends the work to {tester} for the live retest.\n"
        f"3. A deploy is not done until {tester}'s live PASS is on the hand-over. A FAIL comes back as a new round —\n"
        "   triage it (code bug / test bug / requirement gap / flake), never retry until green.\n"
        "4. Load-bearing claim? Hand it and the raw evidence to the reviewer agent before saying \"done\".\n"
        f"Never open {tester}'s tests to see what failed — not seeing them is the point."
    )


def main():
    try:
        ev = json.load(sys.stdin)
    except Exception:
        return
    if ev.get("tool_name") != "Bash":
        return
    t = load_targets()
    if t is None:
        return
    hits = detect((ev.get("tool_input") or {}).get("command", "") or "", t)
    if not hits:
        return
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                             "additionalContext": message(", ".join(hits), t["tester"])}}))


def selftest():
    import subprocess
    import tempfile
    tmp = tempfile.mkdtemp(prefix="post-deploy-")
    cfg = os.path.join(tmp, "pair.yaml")
    with open(cfg, "w") as f:
        json.dump({"tester": {"name": "Sentinel"},
                   "repos": [{"app": "api", "services": ["payments-gateway", "ledger-worker"],
                              "infra": ["pay-dev", "pay-dev-mid"], "sut_namespaces": ["checker-inst-api"]}]}, f)
    empty = os.path.join(tmp, "empty.yaml")
    with open(empty, "w") as f:
        json.dump({"tester": {"name": "Sentinel"}, "repos": [{"app": "api"}]}, f)
    cases = [
        (True, cfg, "kubectl -n pay-dev-mid set image deploy/payments-gateway a=b"),
        (True, cfg, "kubectl apply -n pay-dev -f x.yaml"),
        (True, cfg, "kubectl --context dev create -f out/x.yaml -n checker-inst-api"),
        (True, cfg, "kubectl -n pay-dev patch deploy x -p '{}'"),
        (True, cfg, "kubectl scale deploy/ledger-worker --replicas=2 -n shared"),
        (True, cfg, "kubectl set env deploy/ledger-worker X=1"),
        (True, cfg, "kubectl -n pay-dev rollout restart deploy/x"),
        (True, cfg, "kubectl apply --server-side -k deploy/overlays/dev-api"),
        (True, cfg, "kustomize build deploy/overlays/payments-gateway | kubectl apply -f -"),
        (True, cfg, "kubectl kustomize deploy/overlays/api | kubectl apply -f -"),
        (True, cfg, "kubectl --namespace=pay-dev delete pod x"),
        (True, cfg, "kubectl -n=pay-dev apply -f x"),
        (True, cfg, "kubectl -n pay-dev get deploy a -o yaml | sed s/a/b/ | kubectl apply -f -"),
        (True, cfg, "helm upgrade --install x chart -n pay-dev"),
        (True, cfg, "helm upgrade payments-gateway ./chart -n other"),
        (True, cfg, "kubectl -n pay-dev autoscale deploy a --max=3"),
        (True, cfg, "kubectl -n pay-dev debug pod/a --image=busybox"),
        (True, cfg, "cd x && kubectl -n pay-dev rollout undo deploy/a"),
        (False, cfg, "kubectl -n pay-dev get pods"),
        (False, cfg, "kubectl -n pay-dev rollout status deploy/payments-gateway"),
        (False, cfg, "kubectl -n other-ns set image deploy/a b=c"),
        (False, cfg, "kubectl diff -k deploy/overlays/api"),
        (False, cfg, "kubectl auth can-i create deployments -n pay-dev"),
        (False, cfg, 'git commit -m "kubectl -n pay-dev set image was the old way"'),
        (False, cfg, "cat > t.md <<'EOF'\nkubectl -n pay-dev apply -f x\nEOF"),
        (False, cfg, "echo 'kubectl -n pay-dev apply -f x'"),
        (False, cfg, "grep -rn 'kubectl -n pay-dev apply' docs/"),
        (False, cfg, "kustomize build deploy/overlays/other | kubectl apply -f -"),
        (False, cfg, "helm upgrade other ./chart -n elsewhere"),
        (False, cfg, "helm template x ./chart -n pay-dev"),
        (False, cfg, "go test ./... && git push"),
        (True, empty, "kubectl apply -n anything -f x.yaml"),
        (True, empty, "helm upgrade x ./chart"),
        (False, empty, "kubectl get pods -A"),
        (False, os.path.join(tmp, "missing.yaml"), "kubectl apply -n pay-dev -f x.yaml"),
    ]
    bad = 0
    for want, c, cmd in cases:
        out = subprocess.run([sys.executable, os.path.realpath(__file__)],
                             input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
                             text=True, capture_output=True, env=dict(os.environ, PAIR_CONFIG=c)).stdout
        got = "PostToolUse" in out
        bad += got != want
        print("PASS" if got == want else "FAIL", "fire " if want else "quiet", os.path.basename(c)[:7],
              cmd.replace("\n", " ")[:80])
    out = subprocess.run([sys.executable, os.path.realpath(__file__)],
                         input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "kubectl apply -n pay-dev -f x"}}),
                         text=True, capture_output=True, env=dict(os.environ, PAIR_CONFIG=cfg)).stdout
    ok = "handoff deployed" in out and "Sentinel's live PASS" in out
    bad += not ok
    print("PASS" if ok else "FAIL", "message names `handoff deployed` and the tester's live PASS")
    print("ALL PASS" if not bad else f"{bad} FAILED")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    main()
