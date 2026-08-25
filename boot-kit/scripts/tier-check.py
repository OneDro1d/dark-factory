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
hydration is worse than no gate: a Tier 2 repo's `UPSTREAM.lock` recorded
`tier-check: PASS` from a machine with an empty `vendor/`, and the same repo FAILED with 10
"violations" once it was populated. The excluded list is printed on every run, because a
scan that skipped half the tree looks identical to one that did not unless it says so.

Exit 0 = every referenced skill is shipped here or explicitly allowed. Exit 1 otherwise.

Detects three reference forms:
    Skill(<name>)                   the invocation form
    ](../<name>/SKILL.md)           the legacy path form
    `<name>` in prose               PROSE-REF -- added 2026-08-25, see below
Fenced code blocks are skipped, so examples that name a skill do not trip the gate.

PROSE-REF, and why it is shaped the way it is. On 2026-08-25 this repo cited a
memory-recall skill it does not ship FOUR times -- as STEP 1 of the engine's own
pipeline, in two separate lists -- while this checker printed PASS. It was blind to the
FORM, not ignorant of the FACT: rewriting one of the four as `Skill(<name>)`, changing
nothing else, turned the same run FAIL.

The opposite failure constrains the fix, so the rule was MEASURED against the known
defects rather than reasoned into place. On the tree that carried them:

    873  backticked tokens in prose                                     (unusable)
    164  hyphenated, bare, and not provided by this repo                (unusable)
     10  ...that ALSO sit in a block naming a component this repo ships  <- the rule
      4  of those 10 were the defect -- i.e. all four of them

The plausible alternative -- "the same LINE also carries a Skill() call or a SKILL.md
link" -- scored 0 of 4: every defect line was bare prose among bare prose, and the
confirmed reference sat elsewhere in the list. That is the same shape link-check was
wrong in (its first-path-segment rule excluded every defect it was written to catch).
MEASURE A CANDIDATE DISCRIMINATOR AGAINST THE KNOWN DEFECTS BEFORE ADOPTING IT.

So a PROSE-REF requires all of: a bare kebab-case token with at least one hyphen (no
slash, dot, space or capital); not provided here; and at least one OTHER token in the
same contiguous block of non-blank lines that IS provided here. A block is the unit
because the defect lines carried no anchor of their own -- the shipped sibling was two
list items away.

The prose class asks "does this repo ship the thing it names", so it counts skills at
ANY depth (a skill inside a substrate template still travels with the repo) and agents
(`agents/<name>.md`). The Skill(<name>) class deliberately does NOT: that form asserts
the name is an invocable, installed skill, and an agent is not one.

Residual judgement -- a hyphenated token that names an example directory, a memory
category or a git hook rather than a component -- is recorded, WITH A REASON, in
`.tiercheckignore` at the repo root:

    # comment
    skills/agent-notepad/*.md -> proj-* # example notepad names, not components

A rule without a `# reason` is a hard error (exit 2). Suppressed counts are ALWAYS
printed, including on success, so the debt stays visible. Same format and same rule as
link-check's `.linkcheckignore`, on purpose: two mechanisms for one judgement drift.
"""
import collections
import fnmatch
import json
import pathlib
import re
import sys

SKILL_CALL = re.compile(r'Skill\(([a-z0-9][a-z0-9-]*)\)')
SKILL_LINK = re.compile(r'\]\((?:\.\./)+([a-z0-9][a-z0-9-]*)/SKILL\.md\)')
FENCE = re.compile(r'^\s*(```|~~~)')
CODE = re.compile(r'`([^`\n]+?)`')
# A hyphen is required. Without it the class matches `authority`, `effect`, `pure` and
# `origin` -- 157 of the 873 backticked tokens here, not one of them a component name.
KEBAB = re.compile(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)+$')
IGNORE_FILE = '.tiercheckignore'


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


def provided(root, excludes=()):
    """Every component this repo SHIPS, by name — skills at any depth, plus agents.

    Wider than shipped() on purpose, and used only by the prose class. The question a
    prose reference raises is "does the thing this repo names travel with the repo",
    and a skill nested inside a substrate template does. Six false positives came from
    answering that with the top-level directory listing alone.

    Agents are included for the same reason and stop there: `Skill(<name>)` asserts the
    name is an invocable, installed skill, so an agent must NOT license that form.
    """
    skip = {'.git'} | set(excludes)
    out = set(shipped(root))
    for skill in root.rglob('SKILL.md'):
        parts = skill.relative_to(root).parts
        if set(parts[:-1]) & skip or len(parts) < 2:
            continue
        out.add(parts[-2])
    for agent in root.rglob('agents/*.md'):
        parts = agent.relative_to(root).parts
        if set(parts[:-1]) & skip:
            continue
        if agent.stem.lower() not in ('readme', 'index'):
            out.add(agent.stem)
    return out


def load_ignores(root):
    """[(file_glob, token_glob, reason)] from <root>/.tiercheckignore.

    Every rule MUST carry a `# reason`. A rule without one is a hard error: silently
    suppressed debt is how the defect this class exists for survived for weeks.
    """
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
        file_glob, _, token_glob = rule.partition('->')
        rules.append((file_glob.strip(), (token_glob.strip() or '*'), reason.strip()))
    return rules


def suppressed_by(rules, relfile, token):
    for file_glob, token_glob, reason in rules:
        if fnmatch.fnmatch(relfile, file_glob) and fnmatch.fnmatch(token, token_glob):
            return reason
    return None


def prose_refs(root, have, excludes=()):
    """[(token, relfile, lineno)] — kebab tokens anchored by a provided sibling.

    The block, not the line, is the unit. Every one of the four defects this was written
    for sat on a line carrying no other reference at all; the shipped sibling was two
    list items away. A line-scoped version of this rule catches none of them.
    """
    skip = {'.git'} | set(excludes)
    out = []
    for md in sorted(root.rglob('*.md')):
        rel = md.relative_to(root)
        if set(rel.parts[:-1]) & skip:
            continue
        try:
            lines = md.read_text().splitlines()
        except (OSError, UnicodeDecodeError):
            continue

        block, in_fence = [], False

        def flush():
            anchors = {t for _, _, toks in block for t in toks if t in have}
            for lineno, _, toks in block:
                for t in toks:
                    if t not in have and anchors - {t}:
                        out.append((t, str(rel), lineno))
            del block[:]

        for lineno, line in enumerate(lines, 1):
            if FENCE.match(line):
                in_fence = not in_fence
                flush()          # a fenced region breaks contiguity
                continue
            if in_fence or not line.strip():
                flush()
                continue
            block.append((lineno, line,
                          [m.group(1).strip() for m in CODE.finditer(line)
                           if KEBAB.match(m.group(1).strip())]))
        flush()
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
    here = provided(root, excludes)
    rules = load_ignores(root)
    refs = referenced(root, excludes)
    missing = {k: v for k, v in refs.items() if k not in have and k not in allow}

    prose, muted = collections.defaultdict(list), []
    for token, relfile, lineno in prose_refs(root, here, excludes):
        if token in allow:
            continue
        reason = suppressed_by(rules, relfile, token)
        if reason:
            muted.append((relfile, lineno, token, reason))
        else:
            prose[token].append((relfile, lineno))

    print('tier-check: %s' % root.name)
    print('  ships     %d skill(s)' % len(have))
    print('  provides  %d component(s) incl. nested skills + agents (prose class only)'
          % len(here))
    print('  references %d distinct skill(s)' % len(refs))
    print('  excluded  %s (lower-tier caches are not this repo\'s content)'
          % ', '.join(sorted(excludes | {'.git'})))
    if allow:
        print('  allowed from a lower tier: %s' % ', '.join(sorted(allow)))
    # Never report a clean bill without also reporting what was suppressed to get it.
    if muted:
        print('  suppressed by %s: %d prose reference(s) — judgement, with reasons'
              % (IGNORE_FILE, len(muted)))
        for relfile, lineno, token, reason in muted:
            print('      %s:%d  `%s`  # %s' % (relfile, lineno, token, reason))

    if not missing and not prose:
        print('PASS  tier-check: every referenced skill is shipped here or allowed')
        return 0

    if missing:
        print('FAIL  tier-check: %d referenced skill(s) neither shipped nor allowed:'
              % len(missing))
        for name in sorted(missing):
            print('  %s' % name)
            for relfile, lineno in missing[name][:4]:
                print('      %s:%d' % (relfile, lineno))
        print('\nEither ship the skill here, or declare it with --allow because it ships in a')
        print('LOWER tier. A reference upward breaks every consumer that is not this machine.')

    if prose:
        print('FAIL  tier-check: %d PROSE-REF — backticked name(s) this repo does not '
              'provide, sitting beside one it does:' % len(prose))
        for name in sorted(prose):
            print('  %s  [PROSE-REF]' % name)
            for relfile, lineno in prose[name][:4]:
                print('      %s:%d' % (relfile, lineno))
        print('\nA PROSE-REF is a component named as `like-this` rather than invoked. If it')
        print('is a skill this tier should ship, ship it. If it belongs to a lower tier,')
        print('describe the ROLE and let the instance bind the name. If it is not a')
        print('component at all, record that judgement — with a reason — in %s.'
              % IGNORE_FILE)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
