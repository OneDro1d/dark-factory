#!/usr/bin/env python3
"""kit-check.py — a kit may only name things this repo actually ships.

WHAT A KIT IS

A kit is a named, installable bundle: the method plus a curated skill set plus whatever
bootstrap that domain needs. It is a MANIFEST, not a copy — `kits/<name>/kit.json` lists
skill names that live in `skills/`, and nothing is duplicated to assemble one.

That choice is the whole design. The alternative — one repo per kit — would have added a
pin, a gate and a drift surface per kit, and this estate's measured pain has always been
pin count, never repo size. `vendor/dark-factory` is already one clone on every machine, so
a kit costs a directory and a JSON file.

WHY THIS CHECK EXISTS

A kit naming a skill it does not ship is the same defect `tier-check.py` catches one level
up: a reference that resolves on the authoring machine and nowhere else. It is invisible to
every other gate — a skill name is not a file path, so no link checker sees it, and the
skill IS present locally, so nothing breaks until somebody else installs the kit.

⚠️ AND THE OVERLAP RULE, which looks like a contradiction and is not.

The estate rule is "one artifact, one home". Kits appear to break it: `agent-notepad` is
named by both `agent-ops` and `knowledge-worker`. It does not. "One home" is about where
content LIVES — exactly one repo owns the directory. A kit only REFERENCES it by name. Two
kits naming one skill create no second copy and nothing to drift; two REPOS shipping one
skill create both. So overlap between kits is expected and this checker does not flag it —
what it flags is a name with no skill behind it.

Usage:
    python3 kit-check.py [<repo-root>]
    python3 kit-check.py --self-test

Exit: 0 = every kit resolves   1 = a kit names something absent   2 = bad arguments
"""
import json
import os
import sys

REQUIRED = ("name", "description", "skills")


def die(msg, code=2):
    sys.stderr.write("FATAL: %s\n" % msg)
    sys.exit(code)


def check_repo(root):
    kits_dir = os.path.join(root, "kits")
    skills_dir = os.path.join(root, "skills")
    hooks_dir = os.path.join(root, "hooks")

    if not os.path.isdir(kits_dir):
        print("PASS  no kits/ directory — nothing to check")
        return 0
    if not os.path.isdir(skills_dir):
        die("kits/ exists but skills/ does not — cannot resolve any kit")

    have_skills = {d for d in os.listdir(skills_dir)
                   if os.path.isfile(os.path.join(skills_dir, d, "SKILL.md"))}
    have_hooks = set(os.listdir(hooks_dir)) if os.path.isdir(hooks_dir) else set()

    kits = sorted(d for d in os.listdir(kits_dir)
                  if os.path.isfile(os.path.join(kits_dir, d, "kit.json")))

    print("=== kit-check ===")
    print("kits   : %d" % len(kits))
    print("skills : %d available" % len(have_skills))
    print("")

    fail = 0
    named = set()
    for k in kits:
        path = os.path.join(kits_dir, k, "kit.json")
        try:
            with open(path, encoding="utf-8") as fh:
                man = json.load(fh)
        except Exception as exc:
            print("FAIL  %-22s unreadable: %s" % (k, exc))
            fail = 1
            continue

        problems = []
        for key in REQUIRED:
            if not man.get(key):
                problems.append("missing or empty `%s`" % key)
        # The directory name IS the address a consumer installs by, so a manifest whose
        # `name` disagrees with it would install under one name and be documented under
        # another.
        if man.get("name") and man["name"] != k:
            problems.append("name %r != directory %r" % (man["name"], k))

        missing_s = [s for s in man.get("skills", []) if s not in have_skills]
        missing_h = [h for h in man.get("hooks", []) if h not in have_hooks]
        if missing_s:
            problems.append("skills not shipped: %s" % ", ".join(sorted(missing_s)))
        if missing_h:
            problems.append("hooks not shipped: %s" % ", ".join(sorted(missing_h)))
        # An empty kit is almost certainly an editing accident, and it would install
        # cleanly and silently do nothing.
        if man.get("skills") == []:
            problems.append("declares zero skills — an empty kit installs nothing")

        named.update(man.get("skills", []))
        if problems:
            fail = 1
            print("FAIL  %-22s %s" % (k, problems[0]))
            for p in problems[1:]:
                print("      %-22s %s" % ("", p))
        else:
            print("ok    %-22s %2d skills, %d hooks"
                  % (k, len(man.get("skills", [])), len(man.get("hooks", []))))

    print("")
    # REPORTED, NOT FAILED. A skill outside every kit is not broken — it may be genuinely
    # standalone, or newly added. But a skill nobody bundled is a skill nobody installs by
    # default, and that is worth seeing rather than discovering later.
    orphans = sorted(have_skills - named)
    if orphans:
        print("note  %d skill(s) in no kit: %s" % (len(orphans), ", ".join(orphans)))
    else:
        print("note  every shipped skill is named by at least one kit")

    print("")
    print("=== RESULT: %s ===" % ("KIT REFERENCES BROKEN" if fail else "CLEAN — every kit resolves"))
    return fail


def self_test():
    """A gate you have only ever seen pass is not a gate you have tested.

    This repo has shipped one that could not fail — publish-gate.sh reported CLEAN on a
    planted canary, with three bugs behind it. So this plants one too.
    """
    import tempfile
    ok = True
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "skills", "alpha"))
        open(os.path.join(d, "skills", "alpha", "SKILL.md"), "w").close()
        os.makedirs(os.path.join(d, "kits", "good"))
        os.makedirs(os.path.join(d, "kits", "bad"))
        with open(os.path.join(d, "kits", "good", "kit.json"), "w") as fh:
            json.dump({"name": "good", "description": "d", "skills": ["alpha"]}, fh)
        with open(os.path.join(d, "kits", "bad", "kit.json"), "w") as fh:
            json.dump({"name": "bad", "description": "d", "skills": ["alpha", "ghost"]}, fh)

        print("--- canary: kit 'bad' names a skill that does not exist ---")
        rc = check_repo(d)
        if rc != 1:
            print("SELFTEST FAIL: THE CANARY WAS NOT CAUGHT (rc=%s) — this gate cannot fail" % rc)
            ok = False

        os.remove(os.path.join(d, "kits", "bad", "kit.json"))
        print("--- control: only the resolving kit remains ---")
        rc = check_repo(d)
        if rc != 0:
            print("SELFTEST FAIL: a clean tree did not return 0 (rc=%s)" % rc)
            ok = False

    print("")
    print("SELFTEST %s" % ("PASS — the gate catches its own canary" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--self-test":
        sys.exit(self_test())
    root = args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    sys.exit(check_repo(os.path.abspath(root)))
