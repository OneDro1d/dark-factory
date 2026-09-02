#!/usr/bin/env python3
"""Fleet audit for the gap CLASSES found by the 2026-09-02/03 install reports.

class 1  DECLARED BUT NOT RUNNABLE -- a declared hook sources a file no lockfile declares.
class 2  DECLARED BUT NO WIRING RECIPE -- declared, absent from the settings template, and
         absent from install.hooksUnwired.
class 3  DANGLING REFERENCE -- a doc names a Skill() the lockfile does not install.
class 4  DECLARED SOURCE DOES NOT RESOLVE -- the lockfile names a path that is not there,
         so the installer prints `missing` and then `install complete`.

⚠️ CLASS 4 EXISTS BECAUSE THIS AUDIT MISSED THE DEFECT IT WAS WRITTEN TO FIND. On
2026-09-03 the Poland Coder installed with `2 missing`: its lockfile still declared
`local:boot-kit/hooks/engram-{pre-compact,stop}.sh`, deleted when those hooks were promoted
to Tier 1 and the SIBLING root lockfile in the same repo was repointed to `upstream:`. The
audit reported 0 findings on that kit, because class 1's first act on a source is
`if not os.path.exists(f): continue` -- it skipped the dead source in order to go looking
for a subtler one. The installer caught it; the gap detector did not.

⚠️ THE SHAPE IS THIS FILE'S OWN, FOR THE THIRD TIME. Its class-2 comments already record a
vacuous template lookup and a substring match that both answered "fine" by not looking.
A silent `continue` is the same bug wearing control flow: **every skip is a claim, and an
unlogged claim cannot be wrong out loud.**

Reads the LOCKFILE, never the local ~/.claude

Engram is the memory store named above. What it is and how to reach it is documented in exactly one place: [Engram](../../starter-kit/instance/AUTHENTICATION.md#engram)
 -- a check that passes on the reference laptop
proves nothing about a fresh machine, which is how every one of these survived.
"""
import glob
import json
import os
import re
import subprocess
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


def _git(cwd, *args):
    try:
        return subprocess.call(["git", "-C", cwd] + list(args),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        return 127


def classify_source(root, vendordir, src, pins):
    """Return (verdict, detail). verdict is ok | dead | unknown.

    ⚠️ `unknown` IS NOT A SYNONYM FOR `dead`, AND THE FIRST VERSION OF THIS FUNCTION
    COLLAPSED THEM TWICE. Measured 2026-09-03: it resolved every `upstream:` source against
    the LOCAL vendor checkout and called a miss "does not exist" -- producing 18 findings
    against loom_storage-ESO whose vendor/dark-factory sat at 22e7064 while its lockfiles
    pinned 6ebfbdc0. This laptop never installs those instances, so its checkout is simply
    old. Every one of the 18 files exists at the pin.

    **The installer FETCHES AT THE PIN; it does not read whatever happens to be checked
    out.** So the question is never "is the file in this working tree" but "is it in the
    tree AT THE PINNED COMMIT" -- and `git cat-file -e <pin>:<path>` answers exactly that,
    regardless of what HEAD points to. Only when the pinned commit itself is not present
    locally is the honest answer `unknown`.

    A `local:` source is never unknown. The repo is right here, so a missing local file is
    always a real finding -- which is precisely the Poland case that produced class 4.
    """
    if src.startswith("local:"):
        p = os.path.join(root, src[len("local:"):])
        return ("ok" if os.path.exists(p) else "dead", p)
    s = src[len("upstream:"):] if src.startswith("upstream:") else src
    top = s.split("/")[0]
    rel = "/".join(s.split("/")[1:])
    vdir = os.path.join(root, vendordir, top)
    if not os.path.isdir(vdir):
        return ("unknown", "upstream `%s` is not vendored in this checkout" % top)

    pin = pins.get(top)
    if pin and os.path.isdir(os.path.join(vdir, ".git")):
        if _git(vdir, "cat-file", "-e", "%s^{commit}" % pin) != 0:
            return ("unknown", "upstream `%s` pin %s is not present in this checkout "
                               "(fetch it, or audit a machine that has it)"
                               % (top, pin[:8]))
        if _git(vdir, "cat-file", "-e", "%s:%s" % (pin, rel)) == 0:
            return ("ok", rel)
        return ("dead", "%s (absent from %s at pin %s)" % (rel, top, pin[:8]))

    # No pin recorded, or the vendored copy is not a git checkout: fall back to the working
    # tree. Weaker, and it is the weaker answer precisely because there is no pin to ask.
    p = os.path.join(root, vendordir, s)
    return ("ok" if os.path.exists(p) else "dead", p)


for repo, root in REPOS:
    # ⚠️ MATCH A PATH SEGMENT, NOT A SUBSTRING. This filter was `if "vendor/" not in p`
    # against the ABSOLUTE path, so any kit living under a directory whose name merely
    # CONTAINS "vendor" was dropped from the audit entirely -- scanned nothing, printed
    # TOTAL: 0, exited clean. Found 2026-09-03 by a fixture directory called
    # `stale-vendor/`, which the suite had named for an unrelated reason.
    # Third time in this file: the class-2 basename match and the class-4 silent skip are
    # the same mistake in different clothes -- **a cheap test standing in for the real one,
    # answering "fine" by not looking.**
    def _vendored(p):
        rel = os.path.relpath(p, root)
        return "vendor" in rel.split(os.sep)[:-1]

    locks = [p for p in
             glob.glob(os.path.join(root, "*.lock.json"))
             + glob.glob(os.path.join(root, "instances", "*", "loom.lock.json"))
             if not _vendored(p)]
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
        ssrc = d.get("install", {}).get("skillSources") or {}
        bins = d.get("install", {}).get("bin") or []
        if isinstance(bins, dict):
            bins = list(bins.keys())
        bsrc = d.get("install", {}).get("binSources") or {}
        # the pinned commit for each upstream -- the ONLY authority on what an install
        # will actually place. What is checked out locally is a convenience, not a fact.
        pins = {k: (v or {}).get("commit")
                for k, v in (d.get("upstreams") or {}).items()
                if isinstance(v, dict)}

        # ---- class 4: a DECLARED SOURCE DOES NOT RESOLVE ----
        # Every declaration family, not only hooks: the failure is a lockfile naming a path
        # that is not there, and nothing about it is specific to hooks.
        unvendored = set()
        for kind, names, srcs in (("hook", declared_hooks, hsrc),
                                  ("skill", set(skills), ssrc),
                                  ("bin", set(bins), bsrc)):
            for n in sorted(names):
                src = srcs.get(n)
                if not src:
                    continue
                verdict, detail = classify_source(inst_root, vendordir, src, pins)
                if verdict == "dead":
                    findings.append((label, 4, "%s %s -> %s DOES NOT EXIST -- the installer "
                                               "prints `missing` and then `install complete`"
                                               % (kind, n, src)))
                elif verdict == "unknown":
                    unvendored.add(detail)
        for u in sorted(unvendored):
            findings.append((label, 0, "%s -- so no upstream: source in it could be "
                                       "checked. NOT a finding about the sources: a "
                                       "failure to probe." % u))

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
        # ⚠️ CLASS 2 IS A TIER-3 QUESTION AND DOES NOT APPLY TO A TIER-2 LAYER. A layer is
        # never installed to a machine -- it is composed by an instance lockfile, and the
        # settings template belongs to that instance (measured: the ESO layer's recipe lives
        # in its minted kit at loom-dev-eso/boot-kit/settings.template.json, not in
        # catalyst.lock.json). Reporting a layer for shipping no wiring recipe demands a file
        # the tier model says must not be there.
        # The discriminator is `instance`: an instance lockfile names one machine, a layer
        # names none. ⚠️ AND THIS EXEMPTION IS PRINTED, NEVER SILENT -- an unannounced skip
        # is the class-4 defect, and this file has now committed that three times.
        is_instance = inst is not None
        if not is_instance and declared_hooks:
            findings.append((label, 0, "TIER-2 LAYER (no `instance`): class 2 not applied. "
                                       "A layer is composed by an instance lockfile and is "
                                       "never installed to a machine, so the wiring recipe "
                                       "belongs to the instance, not here."))
        if tmpl:
            wired_text = open(tmpl, encoding="utf-8", errors="replace").read()
        elif declared_hooks and is_instance:
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

for cls in (1, 2, 3, 4):
    rows = [f for f in out if f[1] == cls]
    name = {1: "DECLARED BUT NOT RUNNABLE", 2: "NO WIRING RECIPE",
            3: "DANGLING Skill() REFERENCE",
            4: "DECLARED SOURCE DOES NOT RESOLVE"}[cls]
    print("=== class %d — %s: %d finding(s)" % (cls, name, len(rows)))
    for label, _, msg in rows:
        print("   %-42s %s" % (label, msg))
    print()

# ⚠️ UNKNOWNS ARE PRINTED, NEVER COUNTED. An unvendored checkout is a limit on what this
# run could see, not a defect in the kit -- and folding it into the total is how a network
# blip or a fresh clone gets written down as drift. Printed because a silent unknown is the
# very failure class 4 exists for: the audit must say what it could not check.
unknowns = [f for f in out if f[1] == 0]
if unknowns:
    print("=== NOT PROBED / NOT APPLICABLE (NOT counted as findings): %d" % len(unknowns))
    for label, _, msg in unknowns:
        print("   %-42s %s" % (label, msg))
    print()

print("TOTAL:", len([f for f in out if f[1] != 0]))
sys.exit(0)
