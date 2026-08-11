#!/usr/bin/env python3
"""link-check.py — fail on markdown links whose target does not exist.

Why this exists: a repo archive sweep once left two downstream bindings linking a
skill into a repo that no longer existed. Both links resolved to nothing, on every
machine, and every gate stayed green — because nothing ever checked. Absence has no
shared path unless something walks it.

Usage:
    python3 link-check.py <root> [<root> ...]
    python3 link-check.py --list-ignored <root>

Exit 0 = no unignored broken links. Exit 1 = broken links found.

Scope: relative markdown links only. http(s)/mailto/anchor-only targets are not
checked (that needs the network); fenced code blocks are skipped, because docs
that teach markdown are full of illustrative links that were never meant to resolve.

Suppressing a known-broken link — `.linkcheckignore` at a root:

    # comment
    stages/**/*.md -> service-anatomy.md # lives in the OneDroid lane, placement TBD

Every rule MUST carry a `# reason`. A rule without one is a hard error: silently
suppressed debt is how the original defect survived for weeks. Suppressed counts
are ALWAYS printed, including on success, so the debt stays visible.
"""
import fnmatch
import os
import pathlib
import re
import sys

LINK = re.compile(r'\]\(([^)\s]+?)(?:\s+"[^"]*")?\)')
FENCE = re.compile(r'^\s*(```|~~~)')
SKIP_PREFIX = ('http://', 'https://', 'mailto:', '#', 'data:', 'ftp://')
IGNORE_FILE = '.linkcheckignore'


def load_ignores(root):
    """Return [(file_glob, target_glob, reason)] from <root>/.linkcheckignore."""
    path = root / IGNORE_FILE
    if not path.exists():
        return []
    rules = []
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if '#' not in line:
            sys.stderr.write(
                '%s:%d: rule has no `# reason` — every suppression must be justified:\n  %s\n'
                % (path, lineno, raw))
            sys.exit(2)
        rule, reason = line.split('#', 1)
        file_glob, _, target_glob = rule.partition('->')
        rules.append((file_glob.strip(), (target_glob.strip() or '*'), reason.strip()))
    return rules


def matches(rules, relfile, target):
    for file_glob, target_glob, reason in rules:
        if fnmatch.fnmatch(relfile, file_glob) and fnmatch.fnmatch(target, target_glob):
            return reason
    return None


def scan(root):
    """Yield (relfile, lineno, target, kind, reason_or_None)."""
    rules = load_ignores(root)
    for md in sorted(root.rglob('*.md')):
        if '/.git/' in str(md):
            continue
        relfile = str(md.relative_to(root))
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
            for m in LINK.finditer(line):
                target = m.group(1)
                if target.startswith(SKIP_PREFIX):
                    continue
                clean = target.split('#')[0]
                if not clean or clean.startswith('/'):
                    continue
                resolved = (md.parent / clean).resolve()
                if resolved.exists():
                    continue
                try:
                    resolved.relative_to(root)
                    kind = 'IN-REPO'
                except ValueError:
                    kind = 'ESCAPES'
                yield relfile, lineno, target, kind, matches(rules, relfile, target)


def main(argv):
    list_ignored = '--list-ignored' in argv
    roots = [pathlib.Path(a).resolve() for a in argv if not a.startswith('--')]
    if not roots:
        sys.stderr.write(__doc__)
        return 2

    broken, ignored = [], []
    for root in roots:
        for relfile, lineno, target, kind, reason in scan(root):
            row = (root, relfile, lineno, target, kind, reason)
            (ignored if reason else broken).append(row)

    if list_ignored:
        print('suppressed by %s: %d' % (IGNORE_FILE, len(ignored)))
        for root, relfile, lineno, target, kind, reason in ignored:
            print('  %s:%d  %s  [%s]  # %s' % (relfile, lineno, target, kind, reason))
        return 0

    # Never report a clean bill without also reporting what was suppressed to get it.
    if ignored:
        print('note: %d known-broken link(s) suppressed by %s '
              '(run --list-ignored to see them and why)' % (len(ignored), IGNORE_FILE))

    if not broken:
        print('PASS  link-check: no broken relative links')
        return 0

    escapes = [b for b in broken if b[4] == 'ESCAPES']
    print('FAIL  link-check: %d broken relative link(s), %d leaving the repo'
          % (len(broken), len(escapes)))
    last = None
    for root, relfile, lineno, target, kind, _ in broken:
        if relfile != last:
            print('  %s' % relfile)
            last = relfile
        print('    :%-5d %-8s %s' % (lineno, kind, target))
    print('\nA link that leaves the repo is the dangerous kind: it can resolve on the')
    print('machine that wrote it and nowhere else. Prefer invoking a skill by name.')
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
