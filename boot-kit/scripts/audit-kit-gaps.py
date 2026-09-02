#!/usr/bin/env python3
"""Fleet audit for the three gap CLASSES found by the 2026-09-02 install reports.

class 1  DECLARED BUT NOT RUNNABLE -- a declared hook sources a file no lockfile declares.
class 2  DECLARED BUT NO WIRING RECIPE -- declared, absent from the settings template, and
         absent from install.hooksUnwired.
class 3  DANGLING REFERENCE -- a doc names a Skill() the lockfile does not install.

Reads the LOCKFILE, never the local ~/.claude

Engram is the memory store named above. What it is and how to reach it is documented in exactly one place: [Engram](../../starter-kit/instance/AUTHENTICATION.md#engram)
 -- a check that passes on the reference laptop
proves nothing about a fresh machine, which is how every one of these survived.
"""
import glob
import json
import os
import re
import sys

# ⚠️ NO HARDCODED PATHS. The first version of this file carried the author's own absolute
# home-directory checkout list -- precisely the defect verify-kit.sh VR2 exists to reject,
# and it would have made this audit silently useless on any other machine while still
# exiting 0. Pass the kit roots as arguments instead.
# (VR2 flagged the ORIGINAL version of this very comment for quoting such a path
#  literally. The gate was right: a rule against absolute home paths does not carve out
#  the prose explaining the rule.)
#
#   python3 boot-kit/scripts/audit-kit-gaps.py <kit-root> [<kit-root> ...]
#
# A kit root is a directory holding a *.lock.json (and optionally instances/*/loom.lock.json).
if len(sys.argv) < 2:
    print(__doc__)
    print("usage: audit-kit-gaps.py <kit-root> [<kit-root> ...]")
    print("\nRefusing to guess where the kits live. A default list would be one machine's\n"
          "layout, and an audit that scans nothing while exiting 0 is worse than none.")
    sys.exit(2)

REPOS = [(os.path.basename(os.path.normpath(a)), os.path.abspath(a))
         for a in sys.argv[1:]]

SOURCE_RE = re.compile(r'^\s*(?:\.|source)\s+"?([^"\s]+)"?', re.M)
SKILL_RE = re.compile(r'Skill\(([a-z0-9-]+)\)')

findings = []


def resolve(root, vendordir, src):
    s = src[len("upstream:"):] if src.startswith("upstream:") else src
    if s.startswith("local:"):
        return os.path.join(root, s[len("local:"):])
    return os.path.join(root, vendordir, s)


for repo, root in REPOS:
    locks = [p for p in
             glob.glob(os.path.join(root, "*.lock.json"))
             + glob.glob(os.path.join(root, "instances", "*", "loom.lock.json"))
             if "vendor/" not in p]
    for lp in sorted(locks):
        d = json.loads(open(lp, encoding="utf-8").read())
        inst = d.get("instance")
        inst = inst.get("name") if isinstance(inst, dict) else inst
        label = "%s/%s" % (repo, inst)
        vendordir = d.get("vendorDir", "vendor")
        inst_root = root  # sources resolve from the REPO root on every lane
        hooks = d.get("install", {}).get("hooks") or []
        hsrc = d.get("install", {}).get("hookSources") or {}
        unwired = d.get("install", {}).get("hooksUnwired") or {}
        # a per-instance wiring record: wired here, deliberately not in the shared
        # template. A recorded decision, not an unaddressed gap.
        per_instance = d.get("install", {}).get("$perInstanceWiring") or ""
        skills = d.get("install", {}).get("skills") or []
        if isinstance(skills, dict):
            skills = list(skills.keys())
        declared_hooks = set(hooks if isinstance(hooks, list) else hooks.keys())

        # ---- class 1: declared hook sources an undeclared file ----
        for h in sorted(declared_hooks):
            src = hsrc.get(h)
            if not src:
                continue
            f = resolve(inst_root, vendordir, src)
            if not os.path.exists(f):
                continue
            try:
                body = open(f, encoding="utf-8", errors="replace").read()
            except Exception:
                continue
            for m in SOURCE_RE.finditer(body):
                ref = m.group(1)
                if "$" not in ref and not ref.startswith("/"):
                    continue
                # normalise the common ../lib/x.sh shape into a declaration name
                mm = re.search(r'\.\./([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+\.sh)', ref)
                if not mm:
                    continue
                need = "%s/%s/%s" % (h.split("/")[0], mm.group(1), mm.group(2))
                if need not in declared_hooks:
                    findings.append((label, 1, "%s sources %s -- not declared" % (h, need)))

        # ---- class 2: declared, no wiring recipe, no exception ----
        # ⚠️ THE TEMPLATE LIVES AT DIFFERENT PATHS ON DIFFERENT KITS, and the first version
        # of this check looked at exactly one of them. Kits with no template were SKIPPED
        # silently and reported clean; loom-dev-eso keeps its at boot-kit/settings.template
        # .json and was missed entirely. A detector that passes vacuously is worse than no
        # detector -- it is the same failure this audit exists to find, one level up.
        CANDS = [
            os.path.join(root, "boot-kit", "config", "settings.json.template"),
            os.path.join(root, "boot-kit", "settings.template.json"),
            os.path.join(root, "boot-kit", "config", "settings.template.json"),
            os.path.join(root, "settings.json.template"),
        ]
        tmpl = next((c for c in CANDS if os.path.exists(c)), None)
        wired_text = ""
        if tmpl:
            wired_text = open(tmpl, encoding="utf-8", errors="replace").read()
        elif declared_hooks:
            # NOT a pass. A kit that declares hooks and ships no wiring recipe leaves every
            # one of them to be wired from memory.
            findings.append((label, 2, "NO settings template found in this kit, yet it "
                                       "declares %d hook(s) -- nothing tells an installer "
                                       "how to wire any of them" % len(declared_hooks)))
        if wired_text:
            for h in sorted(declared_hooks):
                # ⚠️ MATCH THE FULL DECLARED NAME, NOT THE BASENAME. Matching the basename
                # under-reports by substring: `agent-notepad/hooks/pre-compact.sh` counted as
                # wired because the template contains `engram-pre-compact.sh`, which ENDS with
                # the same characters. A check that silently answers "already fine" is the
                # exact defect this audit hunts, and it was in the audit.
                base = h.split("/")[-1]
                hit = (h in wired_text
                       or ("/" + base) in wired_text
                       or wired_text.count(base) and any(
                           seg.endswith("/" + base)
                           for seg in wired_text.replace('"', " ").split()))
                if hit:
                    continue
                if h in unwired:
                    continue
                # ⚠️ A THIRD STATE EXISTS AND THE FIRST VERSION OF THIS RULE DENIED IT.
                # "in the shared template" and "in hooksUnwired" are not the only honest
                # endings: a hook can be wired on ONE machine and deliberately absent from a
                # template several instances share. Forcing that into the template wires it
                # everywhere; forcing it into hooksUnwired claims it is inert while it runs.
                # $perInstanceWiring records it, and an audit that keeps reporting a recorded
                # decision is a false alarm -- the exact defect this audit was built to find,
                # committed by the audit. Measured 2026-09-02: 2 findings that could never
                # be actioned because both endings were wrong.
                if h in str(per_instance):
                    continue
                findings.append((label, 2, "%s: declared, not in settings template, no "
                                          "hooksUnwired record" % h))

        # ---- class 3: docs naming a Skill() this lockfile does not install ----
        for doc in ("START-HERE.md", "README.md", "CLAUDE.md"):
            dp = os.path.join(root, doc)
            if not os.path.exists(dp):
                continue
            body = open(dp, encoding="utf-8", errors="replace").read()
            for m in SKILL_RE.finditer(body):
                sk = m.group(1)
                # the line this match sits on -- prose ABOUT a dangling reference is not one
                line_start = body.rfind("\n", 0, m.start()) + 1
                line_end = body.find("\n", m.end())
                line = body[line_start:line_end if line_end != -1 else len(body)]
                if "dangling" in line.lower() or "used to open" in line.lower():
                    continue
                if sk not in skills:
                    findings.append((label, 3, "%s cites Skill(%s), not in install.skills"
                                               % (doc, sk)))

seen = set()
out = []
for f in findings:
    if f in seen:
        continue
    seen.add(f)
    out.append(f)

for cls in (1, 2, 3):
    rows = [f for f in out if f[1] == cls]
    name = {1: "DECLARED BUT NOT RUNNABLE", 2: "NO WIRING RECIPE",
            3: "DANGLING Skill() REFERENCE"}[cls]
    print("=== class %d — %s: %d finding(s)" % (cls, name, len(rows)))
    for label, _, msg in rows:
        print("   %-42s %s" % (label, msg))
    print()

print("TOTAL:", len(out))
sys.exit(0)
