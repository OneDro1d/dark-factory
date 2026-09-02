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

Scope, two classes:

  IN-REPO / ESCAPES   relative markdown links — `[text](target)`.
  PROSE-REF           a reference written as a backticked path — `_meta/AXIOMS.md` —
                      which is how four dangling references shipped on public main
                      while this checker printed PASS. It was blind to the FORM, not
                      ignorant of the FACT: rewriting one of them as a markdown link,
                      same target, turned the same run FAIL.

http(s)/mailto/anchor-only targets are not checked (that needs the network); fenced
code blocks are skipped for BOTH classes, because docs that teach markdown are full of
illustrative links that were never meant to resolve.

PROSE-REF is deliberately narrow, because the opposite failure is just as real. Every
backticked `*.md` token is 396 tokens here and 213 of them do not resolve — almost all
correctly, since `NOTES.md` names a KIND of file the reader will create, not a link. A
gate that fires 200 times is one people learn to override. So a PROSE-REF must carry a
DIRECTORY component, and it resolves against the file's own directory AND every ancestor
up to the root — a doc inside a template addresses its siblings from the template root,
not from itself. That narrows 213 to 15.

Neither class can tell a MENTION from a USE, and no syntactic rule can: `docs/x.md` may
be a file this repo should contain or a path the reader is told to CREATE downstream.
That judgement is a human one, so it is recorded — with a reason — in `.linkcheckignore`.

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
CODE = re.compile(r'`([^`\n]+?)`')
FENCE = re.compile(r'^\s*(```|~~~)')
SKIP_PREFIX = ('http://', 'https://', 'mailto:', '#', 'data:', 'ftp://')
IGNORE_FILE = '.linkcheckignore'
# A backticked token is only a candidate reference if it looks like a PATH, not prose.
PROSE_REJECT = set(' \t|<>*"\'`')


def prose_candidate(token):
    """True if a backticked token is narrow enough to be treated as a reference.

    Requires a directory component on purpose: a bare `NOTES.md` names a kind of file,
    not a location, and treating those as links produces ~200 findings of which almost
    none are defects.
    """
    if not token.endswith('.md') or '/' not in token:
        return False
    if any(c in token for c in PROSE_REJECT):
        return False
    return not token.startswith(SKIP_PREFIX) and not token.startswith(('/', '~'))


def resolves(md, root, clean):
    """True if `clean` names an existing file INSIDE root, from the doc's dir or any ancestor.

    A candidate that resolves to something outside the repo is deliberately NOT a
    resolution: that is the `../../DESIGN.md` shape which finds a sibling checkout on the
    machine that wrote it and nothing anywhere else.
    """
    base = md.parent
    while True:
        cand = (base / clean).resolve()
        if cand.exists():
            try:
                cand.relative_to(root)
                return True
            except ValueError:
                pass          # resolves, but outside the repo — not a resolution
        if base == root:
            return False
        base = base.parent


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


def scan(root, bound=None):
    """Yield (relfile, lineno, target, kind, reason_or_None)."""
    # ⚠️ ROOT DID TWO JOBS AND THEY ARE NOT THE SAME JOB. `root` says WHAT TO SCAN;
    # `bound` says WHAT COUNTS AS INSIDE THE REPO. Conflating them made every caller
    # that scans a SUBDIRECTORY report its own correct cross-directory references as
    # broken: verify-kit.sh passes boot-kit/, so `../working-repos.md` -- a file that
    # exists at the repo root -- resolved outside the given root and was rejected.
    # ⚠️ THE CHECKER WAS RIGHT AND THE CALLER WAS WRONG, which is the worst shape for a
    # gate: three real, resolvable references reported broken on every run. A false
    # alarm is worse than no alarm, because it teaches the reader to skip the output.
    bound = bound or root
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
                    resolved.relative_to(bound)
                    kind = 'IN-REPO'
                except ValueError:
                    kind = 'ESCAPES'
                yield relfile, lineno, target, kind, matches(rules, relfile, target)
            # Second pass: references written as backticked prose rather than as links.
            for m in CODE.finditer(line):
                target = m.group(1).strip()
                if not prose_candidate(target):
                    continue
                clean = target.split('#')[0]
                if resolves(md, bound, clean):
                    continue
                yield relfile, lineno, target, 'PROSE-REF', matches(rules, relfile, target)


def main(argv):
    list_ignored = '--list-ignored' in argv
    # --resolve-root=PATH separates the RESOLUTION BOUNDARY from the SCAN SCOPE. Scan a
    # subdirectory, still resolve against the repo that contains it. Without it, every caller
    # that scans a subtree gets false breakage on references that legitimately point up.
    bound_arg = next((a.split('=', 1)[1] for a in argv
                      if a.startswith('--resolve-root=')), None)
    bound = pathlib.Path(bound_arg).resolve() if bound_arg else None
    roots = [pathlib.Path(a).resolve() for a in argv if not a.startswith('--')]
    if not roots:
        sys.stderr.write(__doc__)
        return 2

    broken, ignored = [], []
    for root in roots:
        for relfile, lineno, target, kind, reason in scan(root, bound):
            row = (root, relfile, lineno, target, kind, reason)
            (ignored if reason else broken).append(row)

    if list_ignored:
        print('suppressed by %s: %d  (each reason says DEBT or DOWNSTREAM)'
              % (IGNORE_FILE, len(ignored)))
        for root, relfile, lineno, target, kind, reason in ignored:
            print('  %s:%d  %s  [%s]  # %s' % (relfile, lineno, target, kind, reason))
        return 0

    # Never report a clean bill without also reporting what was suppressed to get it.
    if ignored:
        print('note: %d reference(s) suppressed by %s — debt or downstream '
              '(run --list-ignored to see them and why)' % (len(ignored), IGNORE_FILE))

    if not broken:
        print('PASS  link-check: no broken relative links')
        return 0

    escapes = [b for b in broken if b[4] == 'ESCAPES']
    prose = [b for b in broken if b[4] == 'PROSE-REF']
    print('FAIL  link-check: %d broken reference(s), %d leaving the repo, %d written as prose'
          % (len(broken), len(escapes), len(prose)))
    last = None
    for root, relfile, lineno, target, kind, _ in broken:
        if relfile != last:
            print('  %s' % relfile)
            last = relfile
        print('    :%-5d %-8s %s' % (lineno, kind, target))
    print('\nA link that leaves the repo is the dangerous kind: it can resolve on the')
    print('machine that wrote it and nowhere else. Prefer invoking a skill by name.')
    if prose:
        print('A PROSE-REF is a path written as `like/this.md` instead of as a link. If it')
        print('points at a file this repo should contain, fix the path and make it a real')
        print('link so it stays checked. If it points at something the READER creates')
        print('downstream, suppress it in %s with that as the reason.' % IGNORE_FILE)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
