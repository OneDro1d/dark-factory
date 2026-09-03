#!/usr/bin/env python3
"""kit-resolve.py — turn a kit NAME into the skills and hooks an instance should declare.

WHY THIS EXISTS

`kits/<name>/kit.json` says which skills a kind of work needs. `starter-kit/instance/` mints a
Tier-3 instance. **Until this script, nothing joined them** — measured: no path under
`starter-kit/` mentioned `kits/`, and `bootstrap.sh` had no skill selection at all, so every
freshly bootstrapped instance shipped `"skills": []` and a `skillSources` map holding only a
comment. The kits were a catalogue nobody could order from.

That is this estate's own recurring defect one level up: a thing DECLARED, shipped, correct,
and wired to nothing. `kit-check.py` proved every kit resolved; no check asked whether any kit
was reachable from an install.

WHAT IT EMITS

JSON on stdout, in the shape the instance lockfile's `install` block wants:

    {"skills": [...], "skillSources": {...}, "hooks": [...], "hookSources": {...},
     "resolvedFrom": ["method-core", "dev"]}

Sources are written `dark-factory/skills/<name>` — the BARE spelling. Both that and
`upstream:dark-factory/...` occur in the estate's lockfiles and the installer accepts either;
the bare form is what the existing kits overwhelmingly use, so it is what a generated record
should look like, for the same reason generated code should look hand-written.

⚠️ `extends` IS THE POINT, AND IT REPLACES A SENTENCE.

`kits/README.md` states that `kits/method-core` is "the floor" and that "the others assume it is
installed alongside". That is a fact about every kit, recorded in prose, enforced by nobody — so
an instance bootstrapped from `kits/frontend` alone would get three skills and none of the
method they depend on, and nothing would say so. A kit now DECLARES what it builds on, and this
resolver walks it. **A dependency that lives only in a README is a dependency the tooling cannot
honour.**

A kit with no `extends` key is left exactly as it is. This is additive: nothing is injected into
a kit that did not ask for it, because a resolver that helpfully adds the floor to every kit
would make `extends` unfalsifiable and would silently overrule a kit that deliberately stands
alone.

Usage:
    python3 kit-resolve.py <kit-name> [<kit-name> ...] [--root <repo-root>]
    python3 kit-resolve.py --list [--root <repo-root>]
    python3 kit-resolve.py --self-test

Exit: 0 ok · 1 a kit names or extends something absent · 2 bad arguments
"""
import json
import os
import sys


def die(msg, code=2):
    sys.stderr.write("FATAL: %s\n" % msg)
    sys.exit(code)


def repo_root_default():
    # boot-kit/scripts/kit-resolve.py -> repo root is two levels up
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load_kit(root, name):
    p = os.path.join(root, "kits", name, "kit.json")
    if not os.path.isfile(p):
        return None, "no kits/%s/kit.json" % name
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh), None
    except ValueError as exc:
        return None, "kits/%s/kit.json is not valid JSON: %s" % (name, exc)


def resolve(root, names):
    """Depth-first over `extends`, floor-first, de-duplicated, order preserved.

    ⚠️ CYCLE-SAFE BY CONSTRUCTION. `visiting` catches a -> b -> a. Without it a cycle is not a
    wrong answer, it is a hang or a RecursionError inside a bootstrap — a failure mode that looks
    like a broken machine rather than a broken manifest.
    """
    skills, hooks, chain = [], [], []
    errors = []
    done, visiting = set(), set()

    def visit(name):
        if name in done:
            return
        if name in visiting:
            errors.append("extends cycle involving %r" % name)
            return
        visiting.add(name)
        kit, err = load_kit(root, name)
        if err:
            errors.append(err)
            visiting.discard(name)
            return
        for parent in kit.get("extends") or []:
            visit(parent)
        for s in kit.get("skills") or []:
            if s not in skills:
                skills.append(s)
        for h in kit.get("hooks") or []:
            if h not in hooks:
                hooks.append(h)
        chain.append(name)
        visiting.discard(name)
        done.add(name)

    for n in names:
        visit(n)
    return skills, hooks, chain, errors


def validate(root, skills, hooks):
    """Every named skill and hook must EXIST in this repo. Same contract as kit-check.py.

    ⚠️ Checked here as well as there on purpose. kit-check.py validates the catalogue; this
    validates one resolution, including everything pulled in through `extends`. A name that
    only becomes reachable via an extends edge is not covered by a per-kit check.
    """
    missing = []
    for s in skills:
        if not os.path.isdir(os.path.join(root, "skills", s)):
            missing.append("skill %s (no skills/%s/)" % (s, s))
    for h in hooks:
        if not os.path.isfile(os.path.join(root, "hooks", h)):
            missing.append("hook %s (no hooks/%s)" % (h, h))
    return missing


def main(argv):
    args = list(argv[1:])
    root = repo_root_default()
    if "--root" in args:
        i = args.index("--root")
        try:
            root = args[i + 1]
        except IndexError:
            die("--root needs a path")
        del args[i:i + 2]

    if "--self-test" in args:
        return self_test()

    kits_dir = os.path.join(root, "kits")
    if not os.path.isdir(kits_dir):
        die("no kits/ under %s" % root)

    if "--list" in args:
        for n in sorted(os.listdir(kits_dir)):
            kit, err = load_kit(root, n)
            if err:
                continue
            ext = kit.get("extends") or []
            tail = ("  extends: " + ", ".join(ext)) if ext else ""
            print("%-22s %2d skills  %s%s" % (n, len(kit.get("skills") or []),
                                              kit.get("description", "")[:60], tail))
        return 0

    names = [a for a in args if not a.startswith("-")]
    if not names:
        die("usage: kit-resolve.py <kit-name> [...] [--root <repo>]")

    skills, hooks, chain, errors = resolve(root, names)
    errors += validate(root, skills, hooks)
    if errors:
        for e in errors:
            sys.stderr.write("ERROR: %s\n" % e)
        return 1

    out = {
        "skills": skills,
        "skillSources": {s: "dark-factory/skills/%s" % s for s in skills},
        "hooks": hooks,
        "hookSources": {h: "dark-factory/hooks/%s" % h for h in hooks},
        "resolvedFrom": chain,
    }
    print(json.dumps(out, indent=2))
    return 0


def self_test():
    """Prove the resolver can FAIL, and prove `extends` actually pulls the floor in.

    This repo has shipped a gate that could not fail — publish-gate.sh once reported CLEAN over a
    planted canary with three bugs behind it — and the lesson was that a check which cannot fail
    is worse than none, because it suppresses the caution its absence would prompt.
    """
    import shutil
    import tempfile

    tmp = tempfile.mkdtemp(prefix="kit-resolve-selftest-")
    try:
        os.makedirs(os.path.join(tmp, "skills", "alpha"))
        os.makedirs(os.path.join(tmp, "skills", "beta"))
        os.makedirs(os.path.join(tmp, "kits", "floor"))
        os.makedirs(os.path.join(tmp, "kits", "upper"))
        os.makedirs(os.path.join(tmp, "kits", "broken"))
        os.makedirs(os.path.join(tmp, "kits", "loopa"))
        os.makedirs(os.path.join(tmp, "kits", "loopb"))

        def w(kit, obj):
            with open(os.path.join(tmp, "kits", kit, "kit.json"), "w", encoding="utf-8") as fh:
                json.dump(obj, fh)

        w("floor", {"name": "floor", "description": "d", "skills": ["alpha"]})
        w("upper", {"name": "upper", "description": "d", "skills": ["beta"],
                    "extends": ["floor"]})
        w("broken", {"name": "broken", "description": "d", "skills": ["nope"]})
        w("loopa", {"name": "loopa", "description": "d", "skills": [], "extends": ["loopb"]})
        w("loopb", {"name": "loopb", "description": "d", "skills": [], "extends": ["loopa"]})

        fails = []

        s, h, chain, errs = resolve(tmp, ["upper"])
        if s != ["alpha", "beta"]:
            fails.append("extends did not pull the floor in first: %r" % s)
        if chain != ["floor", "upper"]:
            fails.append("resolution chain wrong: %r" % chain)
        if errs:
            fails.append("clean case reported errors: %r" % errs)

        s, h, chain, errs = resolve(tmp, ["broken"])
        if not validate(tmp, s, h):
            fails.append("a kit naming a skill that does not exist was NOT caught")

        s, h, chain, errs = resolve(tmp, ["loopa"])
        if not any("cycle" in e for e in errs):
            fails.append("an extends cycle was not reported: %r" % errs)

        s, h, chain, errs = resolve(tmp, ["ghost"])
        if not errs:
            fails.append("a kit that does not exist was not reported")

        # a kit with no `extends` must be left alone — no floor injected
        s, h, chain, errs = resolve(tmp, ["floor"])
        if chain != ["floor"] or s != ["alpha"]:
            fails.append("a kit without extends was modified: %r %r" % (chain, s))

        for f in fails:
            sys.stderr.write("SELF-TEST FAIL: %s\n" % f)
        if fails:
            return 1
        print("kit-resolve self-test: 5 cases, all pass "
              "(extends pulls the floor, missing skill caught, cycle caught, "
              "absent kit caught, no-extends left alone)")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
