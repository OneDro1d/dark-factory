#!/usr/bin/env python3
"""canonical-home.py — one artifact, one home. Fails when a skill name has two.

WHY THIS EXISTS, and why a document was not enough.

The rule "a skill lives in exactly one repo; instances COMPOSE, they do not copy" has been
written down and agreed at least THREE times in the reference estate — 2026-06-22
("one canonical home per skill; dev-kits are pointers"), 2026-08-02 and 2026-08-03/04
("content lives in exactly one place"). Each time, drift followed. By 2026-08-30 one laptop
had FOUR variants of each of three skill stems installed simultaneously — twelve skills
where three would do, with overlapping trigger phrases and no basis for the model to choose
between them.

Nothing detected that, because nothing was looking. `tier-check.py` asks whether a lower
tier REFERENCES a skill it does not ship. `lock-verify` L7 cross-checks declarations against
sources WITHIN one lockfile. Neither can see two lockfiles at once, and the collision only
exists across them. So the fourth write-down of the rule would have decayed like the first
three; this is the rule expressed as something that fails.

WHAT IT CHECKS

Given N lockfiles (one per tier/instance), for every skill NAME declared in more than one:

  D1 duplicate declaration   the same name declared by two different lockfiles
  D2 stem collision          two names sharing a stem (`x` and `<prefix>-x`), which is how
                             the estate's real collisions actually appeared — nobody
                             declares the same name twice, they declare `trilix-x` beside
                             `x` and both install

⚠️ D2 IS A REPORT, NOT ALWAYS A DEFECT — and the distinction is measured, not guessed.
A stem collision is legitimate when the specialised skill is a genuine DELTA of the general
one. It is a defect when they are unrelated skills that merely collide on a name, because
then the shared stem makes the model pick arbitrarily between two things that do different
jobs. Measured on the reference estate: `trilix-requirements-discovery` shares 15 of 22
headings with its Tier-1 namesake (a real fork, strip it to a delta), while
`trilix-develop-and-test` shares 4 of 24 (an unrelated skill — the fix is to RENAME it,
and "strip it to a delta" would have destroyed working content).

So this reports the OVERLAP with each collision and lets a human read the number. It does
not guess the remedy, because the remedy inverts on that number.

Usage:
    python3 canonical-home.py <lockfile> [<lockfile> ...] [--skills-root NAME=PATH ...]
    python3 canonical-home.py --self-test

Exit: 0 = no duplicate declarations   1 = duplicates found   2 = bad arguments
"""
import json
import os
import re
import sys
from collections import defaultdict


def die(msg, code=2):
    sys.stderr.write("FATAL: %s\n" % msg)
    sys.exit(code)


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as exc:
        die("cannot read %s: %s" % (path, exc))


def declared_skills(lock):
    """install.skills, tolerating both shapes the estate has used.

    The array shape is current. The old MAP shape (name -> source) is refused by the
    installers, but this gate must still SEE it: a lockfile in a shape nothing installs
    still declares intent, and reporting "0 skills" for it would read as clean.
    """
    inst = lock.get("install") or {}
    sk = inst.get("skills")
    if sk is None:
        return []
    if isinstance(sk, list):
        return [s for s in sk if isinstance(s, str)]
    if isinstance(sk, dict):
        return list(sk.keys())
    return []


def headings(path):
    """The set of markdown headings in a SKILL.md — the structural fingerprint.

    Headings rather than lines because prose gets rewritten while structure survives: a
    genuine fork keeps its parent's shape even after every sentence is reworded, and an
    unrelated skill does not, however similar its vocabulary.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            body = fh.read()
    except Exception:
        return None
    return {h.strip().lower() for h in re.findall(r"^#{1,6}\s+(.+?)\s*$", body, re.M)}


def cites_parent(special, general, roots):
    """Does the specialised skill NAME the general one? Then it is a binding, not a clone.

    The estate's own convention makes this checkable: a correct binding says so out loud —
    "the generic machinery lives in Skill(x), this supplies the bindings only". That
    sentence is the difference between a delta and an accidental name collision, and it is
    the only signal available without reading both files properly.
    """
    for root in roots.values():
        p = os.path.join(root, special, "SKILL.md")
        if not os.path.isfile(p):
            continue
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                body = fh.read()
        except Exception:
            continue
        if re.search(r"Skill\(%s\)" % re.escape(general), body):
            return True
        if re.search(r"`%s`" % re.escape(general), body):
            return True
    return False


def stem_of(name, prefixes):
    for p in prefixes:
        if name.startswith(p + "-"):
            return name[len(p) + 1:]
    return None


def main(argv):
    locks = [a for a in argv if not a.startswith("--")]
    roots = {}
    it = iter(argv)
    for a in it:
        if a == "--skills-root":
            try:
                spec = next(it)
            except StopIteration:
                die("--skills-root needs NAME=PATH")
            if "=" not in spec:
                die("--skills-root wants NAME=PATH, got %r" % spec)
            k, v = spec.split("=", 1)
            roots[k] = v
            if spec in locks:
                locks.remove(spec)
    if not locks:
        die("no lockfiles given")

    # name -> {supplying repo, ...}
    #
    # ⚠️ KEYED ON THE SUPPLYING REPO, NOT ON THE INSTANCE. Two instances both installing
    # `handoff` is not a duplicate — it is the tier model working exactly as intended:
    # instances COMPOSE, they do not own. The defect is one NAME supplied by two different
    # REPOS, because then there are two copies to maintain and they will drift.
    #
    # The first draft of this gate keyed on the instance label and would have fired on
    # every skill shared by two machines — a gate whose findings are all false is a gate
    # that gets turned off in a week. Found by running it against the real estate.
    where = defaultdict(set)
    for lp in locks:
        lock = load(lp)
        srcs = (lock.get("install") or {}).get("skillSources") or {}
        label = lock.get("instance") or os.path.basename(os.path.dirname(os.path.abspath(lp))) or lp
        for s in declared_skills(lock):
            src = srcs.get(s) or ""
            if src.startswith("local:"):
                supplier = "local:%s" % label      # this instance owns it outright
            elif src:
                supplier = src.split("/")[0].replace("upstream:", "")
            else:
                supplier = "<undeclared-source>"
            where[s].add(supplier)

    print("=== canonical-home ===")
    print("lockfiles : %d" % len(locks))
    print("skills    : %d distinct name(s)" % len(where))
    print("")

    fail = 0

    # ---- D1: the same NAME declared by two lockfiles -------------------------
    print("[D1] no skill name is supplied by two different repos")
    dups = {n: ls for n, ls in where.items() if len(ls) > 1}
    if dups:
        fail = 1
        print("FAIL  D1 %d name(s) supplied by more than one repo:" % len(dups))
        for n in sorted(dups):
            print("        %-38s %s" % (n, ", ".join(sorted(dups[n]))))
        print("        one artifact, one home. Keep it in the LOWEST tier that needs it and")
        print("        delete the others, or rename so they are genuinely distinct skills.")
    else:
        print("PASS  D1 every skill name has exactly one supplying repo (%d checked)" % len(where))
    print("")

    # ---- D2: stem collisions, reported with their measured overlap -----------
    print("[D2] stem collisions, with structural overlap")
    prefixes = sorted({n.split("-", 1)[0] for n in where if "-" in n})
    collisions = []
    for n in sorted(where):
        st = stem_of(n, prefixes)
        if st and st in where and st != n:
            collisions.append((n, st))
    if not collisions:
        print("PASS  D2 no stem collisions")
    else:
        print("REPORT D2 %d stem collision(s) — read the overlap, the remedy inverts on it:" % len(collisions))
        for special, general in collisions:
            a = b = None
            for label, root in roots.items():
                pa, pb = os.path.join(root, special, "SKILL.md"), os.path.join(root, general, "SKILL.md")
                if a is None and os.path.isfile(pa):
                    a = headings(pa)
                if b is None and os.path.isfile(pb):
                    b = headings(pb)
            if a and b:
                shared = len(a & b)
                pct = (100.0 * shared / len(b)) if b else 0.0
                if cites_parent(special, general, roots):
                    # ⚠️ THE THIRD CATEGORY, and it inverts the reading of a LOW score.
                    # A binding deliberately restates nothing — it names the general skill
                    # and supplies only this estate's slots. Near-zero overlap is what a
                    # CORRECT binding looks like, so scoring it "unrelated, rename" is
                    # exactly backwards. Found by running this gate against a real estate,
                    # where a 0/22 binding was flagged for renaming.
                    verdict = "BINDING — cites its parent; low overlap is correct"
                elif pct >= 50:
                    verdict = "FORK — strip to a delta"
                else:
                    verdict = "UNRELATED — rename, do not strip"
                print("        %-38s vs %-26s %d/%d headings (%.0f%%)  %s"
                      % (special, general, shared, len(b), pct, verdict))
            else:
                print("        %-38s vs %-26s overlap UNMEASURED (pass --skills-root to measure)"
                      % (special, general))
        print("        ⚠️ NOT counted as a failure. A specialised skill may legitimately")
        print("        share a stem with the general one. What must not happen is two")
        print("        UNRELATED skills sharing it — the model then picks arbitrarily.")
    print("")

    if fail:
        print("=== RESULT: DUPLICATE DECLARATIONS ===")
    else:
        print("=== RESULT: CLEAN — every skill has one home ===")
    return fail


# ---- self-test: this gate must be able to FAIL ------------------------------
# The reference estate's own publish-gate once reported CLEAN on a planted canary, with
# three bugs behind it. The lesson recorded at the time — "a gate that cannot fail is worse
# than none, it suppresses the caution its absence would prompt" — is why this ships with a
# canary it must catch, runnable with no fixtures and no network.
def self_test():
    import tempfile
    ok = True

    def mk(d, name, sources):
        p = os.path.join(d, name + ".json")
        with open(p, "w", encoding="utf-8") as fh:
            json.dump({"instance": name,
                       "install": {"skills": list(sources), "skillSources": sources}}, fh)
        return p

    with tempfile.TemporaryDirectory() as d:
        # CLEAN: two instances both install `alpha`, and BOTH get it from the same repo.
        # That is the tier model working — instances compose. It must NOT fire.
        clean = [
            mk(d, "t1", {"alpha": "up-a/skills/alpha", "beta": "up-a/skills/beta"}),
            mk(d, "t2", {"alpha": "up-a/skills/alpha", "gamma": "up-b/skills/gamma"}),
        ]
        # CANARY: `alpha` supplied by TWO DIFFERENT repos. Two copies, guaranteed drift.
        planted = [
            mk(d, "t1c", {"alpha": "up-a/skills/alpha"}),
            mk(d, "t2c", {"alpha": "up-b/skills/alpha"}),
        ]

        rc_clean = main(clean)
        print("--- canary: 'alpha' supplied by two different repos ---")
        rc_planted = main(planted)

        if rc_clean != 0:
            print("SELFTEST FAIL: clean fixture did not return 0 (got %s)" % rc_clean)
            ok = False
        if rc_planted != 1:
            print("SELFTEST FAIL: THE CANARY WAS NOT CAUGHT (got %s) — this gate cannot fail" % rc_planted)
            ok = False

        # the map shape must be seen, not silently read as empty
        mapshape = os.path.join(d, "mapshape.json")
        with open(mapshape, "w", encoding="utf-8") as fh:
            json.dump({"instance": "old", "install": {"skills": {"alpha": "upstream:x"}}}, fh)
        if declared_skills(load(mapshape)) != ["alpha"]:
            print("SELFTEST FAIL: the old MAP lockfile shape read as empty")
            ok = False

    print("")
    print("SELFTEST %s" % ("PASS — the gate catches its own canary" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.stderr.write(__doc__)
        sys.exit(2)
    if args[0] == "--self-test":
        sys.exit(self_test())
    sys.exit(main(args))
