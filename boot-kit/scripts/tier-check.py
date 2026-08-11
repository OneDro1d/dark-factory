#!/usr/bin/env python3
"""tier-check.py — fail when a repo references a skill it does not ship.

The tier rule: a lower tier must be self-contained. Tier 1 (this repo) may depend on
nothing above it; Tier 2 may depend on Tier 1; Tier 3 on Tier 1 + Tier 2. A tier that
cites a skill from above it cannot be consumed on its own — the citation resolves on the
authoring machine and nowhere else.

That failure is invisible to every other gate. A skill reference is not a file path, so
a link checker never sees it; and the skill IS installed on the machine that wrote it, so
nothing locally is broken. It only breaks for the next consumer. This walks it explicitly.

Usage:
    python3 tier-check.py <repo> [--allow <name> ...] [--exclude <dir> ...]

    --allow NAME   a skill this repo may reference without shipping (i.e. it ships in a
                   LOWER tier). Repeatable. Tier 1 should pass with no --allow at all.
    --exclude DIR  a directory NAME to skip, matched at any depth. Repeatable. `.git` and
                   the vendor directory (read from `*.lock.json` → `vendorDir`, defaulting
                   to `vendor`) are always excluded; below is why that is not optional.

VENDOR IS NOT THIS REPO'S CONTENT. `vendor/` is a generated cache of a LOWER tier, and a
lower tier referencing its own skills is legal by definition. Walking it attributed Tier 1's
internal `Skill()` calls to the Tier 2 repo that had merely cached it — so the verdict
flipped on whether anyone had run `install.sh` yet. A gate whose answer depends on cache
hydration is worse than no gate: `dark-factory-onedroid/UPSTREAM.lock` recorded
`tier-check: PASS` from a machine with an empty `vendor/`, and the same repo FAILED with 10
"violations" once it was populated. The excluded list is printed on every run, because a
scan that skipped half the tree looks identical to one that did not unless it says so.

Exit 0 = every referenced skill is shipped here or explicitly allowed. Exit 1 otherwise.

Detects both reference forms:
    Skill(<name>)                   the invocation form
    ](../<name>/SKILL.md)           the legacy path form
Fenced code blocks are skipped, so examples that name a skill do not trip the gate.
"""
import collections
import json
import pathlib
import re
import sys

SKILL_CALL = re.compile(r'Skill\(([a-z0-9][a-z0-9-]*)\)')
SKILL_LINK = re.compile(r'\]\((?:\.\./)+([a-z0-9][a-z0-9-]*)/SKILL\.md\)')
FENCE = re.compile(r'^\s*(```|~~~)')


def shipped(root):
    out = set()
    for sub in ('skills', 'bindings'):
        d = root / sub
        if d.is_dir():
            out |= {p.name for p in d.iterdir() if p.is_dir() and (p / 'SKILL.md').exists()}
    return out


def vendor_dirs(root):
    """Every directory this repo treats as a generated cache of a lower tier.

    Read from the lockfiles rather than assumed, because vendorDir is configurable and a
    hard-coded 'vendor' would silently stop excluding the moment someone renamed it.
    'vendor' stays in the set as the documented default.
    """
    out = {'vendor'}
    for lock in sorted(root.glob('*.lock.json')):
        try:
            name = json.loads(lock.read_text()).get('vendorDir')
        except (OSError, ValueError):
            continue
        if isinstance(name, str) and name.strip():
            out.add(name.strip().strip('/'))
    return out


def referenced(root, excludes=()):
    """{skill_name: [(relpath, lineno), ...]}"""
    skip = {'.git'} | set(excludes)
    refs = collections.defaultdict(list)
    for md in sorted(root.rglob('*.md')):
        if set(md.relative_to(root).parts[:-1]) & skip:
            continue
        try:
            lines = md.read_text().splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        in_fence = False
        for lineno, line in enumerate(lines, 1):
            if FENCE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for m in list(SKILL_CALL.finditer(line)) + list(SKILL_LINK.finditer(line)):
                refs[m.group(1)].append((str(md.relative_to(root)), lineno))
    return refs


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    # Parse by walking, not by index(): the previous form took everything after the FIRST
    # --allow, so a later flag's values were silently swallowed into the allow list.
    root, allow, excludes, flag = None, set(), set(), None
    for arg in argv:
        if arg in ('--allow', '--exclude'):
            flag = arg
        elif arg.startswith('--'):
            sys.stderr.write('tier-check: unknown flag %s\n' % arg)
            return 2
        elif flag == '--allow':
            allow.add(arg)
        elif flag == '--exclude':
            excludes.add(arg.strip('/'))
        elif root is None:
            root = pathlib.Path(arg).resolve()
        else:
            sys.stderr.write('tier-check: unexpected argument %s\n' % arg)
            return 2
    if root is None:
        sys.stderr.write(__doc__)
        return 2

    excludes |= vendor_dirs(root)
    have = shipped(root)
    refs = referenced(root, excludes)
    missing = {k: v for k, v in refs.items() if k not in have and k not in allow}

    print('tier-check: %s' % root.name)
    print('  ships     %d skill(s)' % len(have))
    print('  references %d distinct skill(s)' % len(refs))
    print('  excluded  %s (lower-tier caches are not this repo\'s content)'
          % ', '.join(sorted(excludes | {'.git'})))
    if allow:
        print('  allowed from a lower tier: %s' % ', '.join(sorted(allow)))

    if not missing:
        print('PASS  tier-check: every referenced skill is shipped here or allowed')
        return 0

    print('FAIL  tier-check: %d referenced skill(s) neither shipped nor allowed:' % len(missing))
    for name in sorted(missing):
        print('  %s' % name)
        for relfile, lineno in missing[name][:4]:
            print('      %s:%d' % (relfile, lineno))
    print('\nEither ship the skill here, or declare it with --allow because it ships in a')
    print('LOWER tier. A reference upward breaks every consumer that is not this machine.')
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
