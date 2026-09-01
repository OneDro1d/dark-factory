#!/usr/bin/env python3
"""tier1-generic.py — is Tier 1 actually generic? Nothing has ever asked.

WHY THIS EXISTS

The whole tier model rests on one property: Tier 1 is the generic method, Tier 2 is what one
company adds. Every gate in this repo checks a consequence of that property and none checks
the property:

    tier-check.py     does a lower tier reference something above it?
    lock-verify L2    is vendored content declared?
    canonical-home    does one skill name have two homes?
    ---               is Tier 1 actually generic?            NOBODY ASKED

Measured 2026-08-30. `skills/develop-and-test/SKILL.md` — the public, generic method — listed
as PREREQUISITES that a Supabase branch, a RabbitMQ instance and a DigitalOcean app be
reachable, told the reader to run `pnpm build:shared`, to write Zod schemas, and to wire
Fastify. That was one estate's purchasing decisions published as the method. The Tier-2
"fork" everyone assumed was the derivative detects the project type across
Go/.NET/Node/Python/Terraform instead — so the FORK WAS THE PORTABLE DOCUMENT, and
"strip the Tier-2 copy back to a delta" would have deleted the generic text and kept the
coupled one, confidently, in the name of tidying.

Past tense because that file was REMOVED on 2026-09-01, not repaired: nothing in the method
referenced it and no loop had invoked it, so the fork in each estate is now the only copy.
The finding stands as this gate's reason for existing — ⚠️ and it is the reason it must keep
running. The offender that motivated a gate leaving the repo is not evidence the class left
with it.

That inversion was found by reading. Reading does not scale and does not run in CI.

WHAT IT CHECKS, AND WHY PRESENCE IS THE WRONG TEST

The naive gate greps for vendor names. It is useless here, because A TOOL SKILL IS ALLOWED
TO NAME ITS TOOL: `vercel-react-best-practices` says "Vercel" 22 times and is correct — the
mission's own model says project-agnostic DOMAIN or TOOL skills belong in Tier 1. Failing
that file would train everyone to switch the gate off, and a gate people switch off is worse
than no gate because it also carries the appearance of one.

So the test is SELF-DECLARATION plus DENSITY:

  self-declaration  a product is exempt inside a skill whose directory name, frontmatter
                    `name:` or `description:` claims it as the subject. `df-app-walkthrough`
                    describes itself as Clerk-based, so Clerk is its subject, not its
                    coupling. Declaring it is the price of being allowed to assume it.

  co-occurrence     ONE undeclared product is an illustration ("e.g. RabbitMQ") and is
                    REPORTED, not failed. Products from TWO DIFFERENT CATEGORIES, composed
                    together in one PROSE BLOCK, is a document written against somebody's
                    stack — the shape both real offenders have.

⚠️ THE RULE WAS FILE-WIDE UNTIL 2026-08-31, AND THAT WAS WRONG IN A THIRD DIRECTION.

It counted categories across the whole artifact. First it counted PRODUCTS, which punished
`Database queries (Prisma, Drizzle, etc.)` — the generic phrasing. Counting categories fixed
that and introduced the mirror defect: a document that must offer alternatives for MORE THAN
ONE CONCERN. `service-mapper/SKILL.md` names four brokers in one table row and an ORM in the
next, which is the most generic writing in the repo, and it failed. It carried a standing
exception whose own text said the fix belonged in the gate.

So the unit of judgement is now a PROSE BLOCK — a run of consecutive non-blank lines that is
neither a table row nor inside a code fence:

    PROSE COMPOSES.   "Dev Supabase project accessible / Dev RabbitMQ accessible / Dev
                      DigitalOcean app exists", three bullets in one block, is a stack. So is
                      "Wire: Fastify, RabbitMQ". These still fail, and the failure now names
                      the block.
    TABLES AND CODE   One concern per row, alternatives inside the row; a grep whose pattern
    ENUMERATE.        lists what to look for. These name several products and compose none.

⚠️ AND THE VOCABULARY IS WHY A CATALOGUE LOOKED LIKE A STACK. Of the five ORMs on that row
the gate knows one; of the three databases on the next it knows one. A menu of five reads as
a lone choice to a reader who can only see one option — so the vocabulary does not merely
miss couplings, it MANUFACTURES the appearance of one in text doing the opposite.

⚠️ THE COST, STATED RATHER THAN BURIED. A genuinely coupled document that never puts two
products in one block now passes. Such a file is still REPORTED — tagged `catalogued not
composed`, which is the weaker verdict and says so — but it does not fail. That is the
deliberate trade: the alternative is failing the most generic writing in the repo, and a gate
that does that is one people switch off.

⚠️ THE VOCABULARY SHIPS — FOR THE THIRD-PARTY CLASS, AND THAT CAVEAT WAS EARNED.

`tier1-generic.conf` is committed, unlike `landmarks.conf` which is gitignored because it
holds real client names — with the consequence that CI runs the placeholder copy and the
publish gate cannot see a real landmark (ticket 12915091248). "Supabase" and "RabbitMQ" are
public product names, so for third-party products this gate runs at full strength in CI on
the first run, with no local configuration.

The first draft claimed that for the WHOLE vocabulary and was wrong. It also listed three
estate-owned library and venue names, and the publish gate rejected the file — two tripped
P1 (client landmarks), one tripped P3 (second-estate). Then it rejected the first attempt at
this very paragraph, which had named the three tokens it was explaining the removal of.

A gate's vocabulary is built out of the exact strings it forbids, so it is textually
indistinguishable from a violation — and so is any note explaining the vocabulary. That is
the same fact that gitignores `landmarks.conf`, met from the other side, twice in one file.

So estate-private tokens live in `tier1-generic.local.conf`, gitignored, merged over the
shipped file when present. The cost is stated rather than buried: for the estate-private
class this gate has exactly the blindness the publish gate has, and a green CI tick does not
mean "no in-house coupling". Every finding so far has come from the third-party class.

EXCEPTIONS CARRY A REASON OR THEY ARE THEMSELVES A FAILURE

`tier1-generic-allow.conf` maps a path to a reason, the same contract as `lock-verify` L9's
`install.hooksUnwired`. An exception with an empty reason is reported as a defect. A gate
with an anonymous mute button becomes a gate people learn to ignore — verify-kit passed for
weeks with 15 mandated skills absent.

Usage:
    python3 tier1-generic.py [<repo-root>] [--vocab PATH] [--allow PATH]
    python3 tier1-generic.py --self-test

Exit: 0 = clean (single-product notes may still print)   1 = coupling found   2 = bad args
"""
import os
import re
import sys

SCAN_DIRS = ("skills", "method", "patterns", "stages", "docs", "kits")
TEXT_EXT = (".md", ".txt", ".json", ".sh", ".py", ".mjs", ".js", ".ts", ".yml", ".yaml", ".conf")
HERE = os.path.dirname(os.path.abspath(__file__))


def die(msg, code=2):
    sys.stderr.write("FATAL: %s\n" % msg)
    sys.exit(code)


def load_vocab(path):
    """product -> category. Categories are `[header]` lines and they are load-bearing:
    the verdict counts distinct CATEGORIES, so a product outside one would be a decision
    with no weight. A token before any header is therefore fatal, not defaulted."""
    if not os.path.isfile(path):
        die("no vocabulary at %s" % path)
    out = {}
    cat = None
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                cat = line[1:-1].strip().lower()
                if not cat:
                    die("%s:%d empty category header" % (path, lineno))
                continue
            if cat is None:
                die("%s:%d product '%s' appears before any [category] header" % (path, lineno, line))
            out[line.lower()] = cat
    if not out:
        die("vocabulary %s is empty — this gate would pass on everything" % path)
    return out


def load_allow(path):
    """path -> reason. A key with no reason is returned with an empty value, ON PURPOSE:
    the caller reports it rather than silently honouring or silently dropping it."""
    allow = {}
    if not os.path.isfile(path):
        return allow
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            key, sep, reason = line.partition("::")
            allow[key.strip()] = reason.strip() if sep else ""
    return allow


def subject_of(root, relpath):
    """Products this artifact's OWNING SKILL declares as its subject.

    Read from the skill directory name plus its SKILL.md frontmatter, and applied to every
    file under that skill — a tool skill's helper scripts and rule files are as entitled to
    name the tool as its SKILL.md is. Outside skills/ there is no owner and nothing is
    exempt, which is deliberate: a stage template or a doc has no subject to plead.
    """
    parts = relpath.split(os.sep)
    if len(parts) < 2 or parts[0] != "skills":
        return ""
    skill_dir = os.path.join(root, "skills", parts[1])
    text = parts[1].lower()
    skill_md = os.path.join(skill_dir, "SKILL.md")
    if os.path.isfile(skill_md):
        try:
            with open(skill_md, encoding="utf-8", errors="replace") as fh:
                head = fh.read(4096)
        except OSError:
            head = ""
        # Frontmatter only. A product named in the BODY is exactly the coupling being
        # looked for, so reading further would let any file exempt itself by mentioning
        # the thing it is coupled to — the gate would pass on its own worst case.
        m = re.match(r"^---\s*\n(.*?)\n---\s*\n", head, re.S)
        if m:
            text += " " + m.group(1).lower()
    return text


def scan_file(path, vocab):
    """-> (totals, blocks). `totals` is token -> count across the whole file. `blocks` is a
    list of (first_lineno, {token}) for PROSE blocks only — a block being a run of
    consecutive non-blank prose lines.

    ⚠️ WHERE A PRODUCT IS NAMED IS PART OF WHAT IT MEANS, and a file-wide tally throws that
    away before the verdict is computed. Two shapes carry opposite meanings:

      PROSE COMPOSES.     "Dev Supabase branch accessible / Dev RabbitMQ accessible / Dev
                          DigitalOcean app exists" is a list of things that must ALL hold.
                          That is a stack, and it is what this gate exists to catch.

      TABLES AND CODE     "| Message bus (RabbitMQ, Kafka, NATS, SQS) | look for publish… |"
      BLOCKS ENUMERATE.   and "| ORM models | Prisma schema, TypeORM entities, GORM models |"
                          are a catalogue of things to go and look for, one row per concern,
                          alternatives inside each row. That is the most generic writing in
                          the repo, and the old rule failed it.

    So table rows (a line whose first non-space character is `|`) and fenced code blocks are
    read as CATALOGUE and excluded from the coupling verdict. Their tokens still count in
    `totals`, so the file is still reported — it is the FAILING verdict they are exempt from,
    not visibility.

    ⚠️ The gate's own vocabulary is why a catalogue looked like a stack in the first place.
    Of the five ORMs on one of those rows it knows one; of the three databases on the next it
    knows one. A menu of five reads as a lone choice to a reader who can only see one option.
    That is F-11 from a third side: the vocabulary does not merely miss things, it
    MANUFACTURES the appearance of coupling in text doing the opposite.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            body = fh.read()
    except OSError:
        return {}, []
    pats = [(tok, re.compile(r"(?<![a-z0-9])%s(?![a-z0-9])" % re.escape(tok))) for tok in vocab]
    totals, blocks = {}, []
    cur_toks, cur_start, in_fence = set(), 0, False
    for lineno, line in enumerate(body.lower().split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
            continue
        hits = set()
        for tok, pat in pats:
            n = len(pat.findall(line))
            if n:
                totals[tok] = totals.get(tok, 0) + n
                hits.add(tok)
        catalogue = in_fence or stripped.startswith("|")
        if not stripped:
            if cur_toks:
                blocks.append((cur_start, cur_toks))
            cur_toks, cur_start = set(), 0
            continue
        if catalogue or not hits:
            continue
        if not cur_toks:
            cur_start = lineno
        cur_toks |= hits
    if cur_toks:
        blocks.append((cur_start, cur_toks))
    return totals, blocks


def check_repo(root, vocab_path=None, allow_path=None, local_path=None):
    shipped = vocab_path or os.path.join(HERE, "tier1-generic.conf")
    vocab = load_vocab(shipped)
    # The gitignored overlay for estate-private product names. Absent is the NORMAL case —
    # in CI and in any fork — so it is not an error, but its absence is REPORTED on the
    # header line. A reader must be able to tell which of the two strengths produced the
    # verdict they are looking at, or the weaker one silently inherits the stronger one's
    # authority. That inheritance is precisely what ticket 12915091248 is about.
    local = local_path or os.path.join(HERE, "tier1-generic.local.conf")
    n_local = 0
    if os.path.isfile(local):
        extra = load_vocab(local)
        n_local = len(extra)
        vocab.update(extra)
    allow = load_allow(allow_path or os.path.join(HERE, "tier1-generic-allow.conf"))

    print("=== tier1-generic ===")
    print("root  = %s" % root)
    if n_local:
        print("vocab = %d product(s) — shipped + %d from the local overlay" % (len(vocab), n_local))
    else:
        print("vocab = %d product(s) — SHIPPED ONLY, no estate-private overlay present."
              % len(vocab))
        print("        Third-party coupling is fully checked; in-house product names are")
        print("        not. Add tier1-generic.local.conf to cover them (gitignored).")
    print("")

    coupled, notes, excused, unreasoned = [], [], [], []
    seen_allow = set()

    for base in SCAN_DIRS:
        top = os.path.join(root, base)
        if not os.path.isdir(top):
            continue
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__", "node_modules")]
            for fn in sorted(filenames):
                if not fn.endswith(TEXT_EXT):
                    continue
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, root)
                found, blocks = scan_file(full, vocab)
                if not found:
                    continue
                subject = subject_of(root, rel)
                undeclared = {t: n for t, n in found.items() if t not in subject}
                if not undeclared:
                    continue
                if rel in allow:
                    seen_allow.add(rel)
                    if allow[rel]:
                        excused.append((rel, allow[rel]))
                    else:
                        unreasoned.append(rel)
                    continue
                # THE VERDICT IS CO-OCCURRENCE, NOT A FILE-WIDE CATEGORY COUNT.
                #
                # Two products from one category are alternatives ("Prisma, Drizzle, etc.").
                # That much the file-wide count already got right. What it got WRONG is a
                # document that offers a menu in each of SEVERAL categories — a service
                # mapper telling you to look for a message bus (RabbitMQ, Kafka, NATS, SQS)
                # and then for ORM models (Prisma schema, TypeORM entities, GORM models) is
                # the most generic possible phrasing, and the old rule failed it for naming
                # two categories.
                #
                # ⚠️ AND THE REASON IT LOOKED LIKE A STACK IS THIS GATE'S OWN VOCABULARY.
                # Of the five ORMs on that line it knows one; of the three databases on the
                # next it knows one. A menu of five reads as a lone choice when the reader
                # can only see one of the options. That is F-11 met from a third side: the
                # vocabulary does not merely fail to catch things, it MANUFACTURES the
                # appearance of coupling in text that is doing the opposite.
                #
                # A stack is products named TOGETHER — "a Supabase branch, a RabbitMQ
                # instance and a DigitalOcean app", "Wire: Fastify, RabbitMQ". A menu is
                # products named INSTEAD of one another, and they never share a sentence
                # with a product from a different concern. So the categories are counted
                # PER LINE, and the failure names the line.
                #
                # ⚠️ The cost, stated rather than buried: a genuinely coupled document that
                # never puts two products in one sentence now passes. That file is still
                # REPORTED (multi-category, never together) — visible, not failed — because
                # the alternative is the false positive above, and a gate that fires on the
                # most generic writing in the repo is one people switch off.
                cats = {vocab[t] for t in undeclared}
                coupling_lines = []
                for start, toks_all in blocks:
                    toks = sorted(t for t in toks_all if t in undeclared)
                    lcats = sorted({vocab[t] for t in toks})
                    if len(lcats) >= 2:
                        coupling_lines.append((start, toks, lcats))
                if coupling_lines:
                    coupled.append((rel, undeclared, sorted(cats), coupling_lines))
                else:
                    notes.append((rel, undeclared, sorted(cats)))

    fail = 0

    if coupled:
        fail = 1
        print("COUPLED  %d artifact(s) written against a specific estate's stack:" % len(coupled))
        for rel, prods, cats, lines in coupled:
            detail = " ".join("%s×%d" % (t, n) for t, n in sorted(prods.items()))
            print("         %s" % rel)
            print("           %d categories (%s): %s" % (len(cats), ", ".join(cats), detail))
            # Name the LINE, not just the file. The old output said which file and left the
            # reader to find the sentence; on a 250-line skill that is a second search, and
            # a diagnostic that stops one step short is one people stop reading.
            for ln, toks, lcats in lines[:5]:
                print("           prose block at line %d names %s (%s)"
                      % (ln, ", ".join(toks), ", ".join(lcats)))
            if len(lines) > 5:
                print("           ... and %d more such block(s)" % (len(lines) - 5))
        print("")
        print("         Each names products it does not declare as its subject. Either move")
        print("         the coupled material down to the Tier-2 layer that owns that stack,")
        print("         or declare the product in this skill's frontmatter and accept that")
        print("         it is a tool skill rather than method.")
        print("")

    if unreasoned:
        fail = 1
        print("NOREASON %d exception(s) listed with no reason:" % len(unreasoned))
        for rel in unreasoned:
            print("         %s" % rel)
        print("         The reason IS the exception. Write `path :: why, and what unblocks it`.")
        print("")

    stale = sorted(set(allow) - seen_allow)
    if stale:
        fail = 1
        print("STALE    %d exception(s) for artifacts that are now clean or gone:" % len(stale))
        for rel in stale:
            print("         %s" % rel)
        print("         Delete them. A standing exception nobody needs is how the next real")
        print("         one gets waved through unread.")
        print("")

    if excused:
        print("EXCUSED  %d recorded exception(s):" % len(excused))
        for rel, reason in excused:
            print("         %s" % rel)
            print("           %s" % reason)
        print("")

    if notes:
        print("NOTE     %d artifact(s) name products but never two concerns TOGETHER —" % len(notes))
        print("         reported, not failed:")
        for rel, prods, cats in notes:
            detail = " ".join("%s×%d" % (t, n) for t, n in sorted(prods.items()))
            tag = cats[0] if len(cats) == 1 else "%d cats, catalogued not composed" % len(cats)
            print("         %-56s [%s] %s" % (rel, tag, detail))
        print("         Products named instead of one another are a menu. Products named")
        print("         together in prose are a stack. The second tag is the WEAKER verdict:")
        print("         those files do span concerns, and it is only their shape — a table")
        print("         row or a code block per concern — that says they are catalogued.")
        print("")

    if not coupled and not unreasoned and not stale:
        print("PASS     no prose block composes undeclared estate products from two categories")
        print("")

    print("=== RESULT: %s ===" % ("NOT GENERIC" if fail else "GENERIC"))
    return fail


def self_test():
    """A gate you have only ever seen pass is not a gate you have tested.

    This repo has shipped one that could not fail — publish-gate.sh reported CLEAN on a
    planted canary with three bugs behind it. So every case below is paired: a canary that
    MUST be caught and a control that MUST NOT, including the two ways this particular gate
    could be wrong in the generous direction (a tool skill failed for naming its own tool)
    and in the permissive direction (a coupled file exempting itself from its own body).
    """
    import tempfile
    ok = True

    def mk(d, rel, body):
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(body)

    def run(d, label, want, vocab, allow=None):
        nonlocal ok
        print("--- %s ---" % label)
        rc = check_repo(d, vocab_path=vocab, allow_path=allow or os.path.join(d, "nope.conf"))
        if rc != want:
            print("SELFTEST FAIL: %s -> rc=%s, wanted %s" % (label, rc, want))
            ok = False
        return rc

    with tempfile.TemporaryDirectory() as d:
        vocab = os.path.join(d, "vocab.conf")
        with open(vocab, "w", encoding="utf-8") as fh:
            fh.write("# test vocabulary\n"
                     "[managed-platform]\nsupabase\nvercel\n"
                     "[broker]\nrabbitmq\nkafka\n"
                     "[app-framework]\nfastify\nprisma\ndrizzle\n")

        # CANARY — the real defect: a generically-named method skill listing a stack.
        mk(d, "skills/develop-and-test/SKILL.md",
           "---\nname: develop-and-test\ndescription: Build and test a service.\n---\n"
           "Prerequisite: a Supabase branch is reachable and RabbitMQ is up.\n"
           "Wire Fastify to the queue.\n")
        run(d, "canary: method skill naming Supabase + RabbitMQ + Fastify", 1, vocab)

        # CONTROL — a tool skill naming ITS OWN tool, many times. Must not fail: this is
        # the case that would make the gate unusable, so it is pinned.
        os.remove(os.path.join(d, "skills/develop-and-test/SKILL.md"))
        mk(d, "skills/vercel-react-best-practices/SKILL.md",
           "---\nname: vercel-react-best-practices\ndescription: Vercel and React rules.\n---\n"
           + "Vercel caching. " * 20)
        mk(d, "skills/vercel-react-best-practices/rules/cache.md", "Vercel edge cache notes.\n")
        run(d, "control: tool skill names its declared subject, incl. a helper file", 0, vocab)

        # CANARY — self-declaration must come from FRONTMATTER ONLY. A file that names its
        # coupling in the body must not thereby exempt itself, or the gate passes on its
        # own worst case.
        mk(d, "skills/service-mapper/SKILL.md",
           "---\nname: service-mapper\ndescription: Map services.\n---\n"
           "This skill is about Supabase and RabbitMQ.\n")
        run(d, "canary: body mentions cannot self-exempt", 1, vocab)

        # CONTROL — the same two products, now genuinely declared in frontmatter.
        mk(d, "skills/service-mapper/SKILL.md",
           "---\nname: service-mapper\ndescription: Map Supabase and RabbitMQ topologies.\n---\n"
           "Read the schema, read the queues.\n")
        run(d, "control: frontmatter declaration exempts", 0, vocab)

        # CONTROL — ONE undeclared product is a note, not a failure.
        mk(d, "skills/security-threat-modeler/SKILL.md",
           "---\nname: security-threat-modeler\ndescription: Threats.\n---\n"
           "Check the broker, e.g. RabbitMQ, for unauthenticated access.\n")
        run(d, "control: a single product is an illustration", 0, vocab)

        # CONTROL — TWO products from ONE category. This is the case the first draft of the
        # gate got WRONG: it counted products, so `Database queries (Prisma, Drizzle, etc.)`
        # in vercel-react-best-practices failed as "coupled" when naming two competing
        # products is the GENERIC phrasing. Pinned so the rule cannot regress to a
        # product count, which would punish exactly the writing style it wants.
        mk(d, "skills/architecture-reviewer/SKILL.md",
           "---\nname: architecture-reviewer\ndescription: Review architecture.\n---\n"
           "Database queries (Prisma, Drizzle, etc.) belong behind a repository.\n")
        run(d, "control: two products, ONE category, is naming alternatives", 0, vocab)

        # CANARY — the matched pair. Same product count, categories spanning, so the fix
        # above cannot become "never fail on two products".
        mk(d, "skills/architecture-reviewer/SKILL.md",
           "---\nname: architecture-reviewer\ndescription: Review architecture.\n---\n"
           "Run Prisma against the Supabase branch.\n")
        run(d, "canary: two products across TWO categories is a stack", 1, vocab)
        os.remove(os.path.join(d, "skills/architecture-reviewer/SKILL.md"))

        # ---- menu vs stack: the shape of the text, not the tally -------------------
        # CANARY — the REAL shape of the offender this gate was built for. Its stack is
        # three consecutive bullets, one product each, so a rule that looked at a single
        # LINE would find one category per line and pass the file. Measured: the first
        # attempt at this fix did exactly that and demoted the canonical offender to a note.
        mk(d, "skills/develop-and-test/SKILL.md",
           "---\nname: develop-and-test\ndescription: Build and test a service.\n---\n"
           "Preconditions:\n"
           "  - Dev Supabase project accessible\n"
           "  - The Fastify service is running\n"
           "  - Run the build\n")
        run(d, "canary: a stack spread down consecutive bullets still couples", 1, vocab)
        os.remove(os.path.join(d, "skills/develop-and-test/SKILL.md"))

        # CONTROL — a CATALOGUE: one concern per table row, alternatives inside the row.
        # This is the false positive that motivated the change (service-mapper), and it is
        # the most generic writing in the repo.
        mk(d, "skills/service-mapper/SKILL.md",
           "---\nname: service-mapper\ndescription: Map services.\n---\n"
           "| Concern | Look for |\n"
           "|---|---|\n"
           "| Message bus (RabbitMQ, Kafka) | publish, subscribe |\n"
           "| DB connection strings | SUPABASE_URL, MONGO_URI |\n")
        run(d, "control: one concern per table row is a catalogue, not a stack", 0, vocab)

        # CONTROL — the same, in a fenced code block: a grep whose pattern lists what to
        # search for names several products and composes none of them.
        mk(d, "skills/service-mapper/SKILL.md",
           "---\nname: service-mapper\ndescription: Map services.\n---\n"
           "Search for the queue and the database:\n\n"
           "```bash\n"
           "grep -rn 'RabbitMQ\\|SUPABASE_URL' .\n"
           "```\n")
        run(d, "control: a fenced code block is a catalogue too", 0, vocab)

        # CANARY — the matched pair for both controls. Same two products, now composed in a
        # sentence, so "tables and code are exempt" cannot become "anything is exempt".
        mk(d, "skills/service-mapper/SKILL.md",
           "---\nname: service-mapper\ndescription: Map services.\n---\n"
           "Point the RabbitMQ consumer at the Supabase project.\n")
        run(d, "canary: the same two products composed in prose DO couple", 1, vocab)
        os.remove(os.path.join(d, "skills/service-mapper/SKILL.md"))

        # CONTROL — STRUCTURAL, and it is the one that keeps the rest honest. If blocks ever
        # stopped splitting on blank lines, every file would collapse into one block and the
        # rule would silently revert to the file-wide count this change replaced. Two
        # paragraphs, one category each, far apart: must pass.
        mk(d, "skills/repo-docs/SKILL.md",
           "---\nname: repo-docs\ndescription: Document a repo.\n---\n"
           "Describe the queue, for example RabbitMQ.\n"
           "\n"
           "Filler paragraph with nothing in it.\n"
           "\n"
           "Separately, note the hosting, for example Vercel.\n")
        run(d, "control: a blank line really does separate blocks", 0, vocab)
        os.remove(os.path.join(d, "skills/repo-docs/SKILL.md"))

        # CANARY — outside skills/ nothing has a subject to plead.
        mk(d, "stages/3-Developer/templates/spec.md",
           "Deploy to Vercel, queue on RabbitMQ.\n")
        run(d, "canary: a stage template cannot self-declare", 1, vocab)

        # CONTROL — a reasoned exception silences that one artifact.
        allow = os.path.join(d, "allow.conf")
        with open(allow, "w", encoding="utf-8") as fh:
            fh.write("stages/3-Developer/templates/spec.md :: blocked on ticket 999\n")
        run(d, "control: a reasoned exception is honoured", 0, vocab, allow)

        # CANARY — an exception with no reason is itself the defect.
        with open(allow, "w", encoding="utf-8") as fh:
            fh.write("stages/3-Developer/templates/spec.md\n")
        run(d, "canary: an exception with no reason fails", 1, vocab, allow)

        # CANARY — a stale exception fails too, so the allow-list cannot silently rot.
        with open(allow, "w", encoding="utf-8") as fh:
            fh.write("stages/3-Developer/templates/spec.md :: blocked on ticket 999\n"
                     "skills/gone/SKILL.md :: this artifact no longer exists\n")
        run(d, "canary: a stale exception fails", 1, vocab, allow)

        # CANARY — an empty vocabulary must be fatal, not a silent pass.
        def fatal_case(label, body, want=2):
            nonlocal ok
            p = os.path.join(d, "bad.conf")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(body)
            print("--- %s ---" % label)
            pid = os.fork()
            if pid == 0:
                try:
                    check_repo(d, vocab_path=p)
                except SystemExit as exc:
                    os._exit(exc.code if isinstance(exc.code, int) else 1)
                os._exit(0)
            _, status = os.waitpid(pid, 0)
            rc = os.WEXITSTATUS(status)
            if rc != want:
                print("SELFTEST FAIL: %s -> rc=%s, wanted %s" % (label, rc, want))
                ok = False

        fatal_case("canary: an empty vocabulary must be FATAL, not a pass",
                   "# nothing but comments\n")
        # A token with no category would carry no weight in a category count — it could
        # never contribute to a verdict, so it must be refused loudly rather than scanned
        # for and silently ignored.
        fatal_case("canary: a product before any [category] header is FATAL",
                   "supabase\n[broker]\nrabbitmq\n")

    print("")
    print("SELFTEST %s" % ("PASS — the gate catches every canary and spares every control"
                           if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--self-test":
        sys.exit(self_test())
    root, vocab_p, allow_p = None, None, None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--vocab":
            i += 1
            vocab_p = args[i] if i < len(args) else die("--vocab needs a path")
        elif a.startswith("--vocab="):
            vocab_p = a.split("=", 1)[1] or die("--vocab= needs a path")
        elif a == "--allow":
            i += 1
            allow_p = args[i] if i < len(args) else die("--allow needs a path")
        elif a.startswith("--allow="):
            allow_p = a.split("=", 1)[1] or die("--allow= needs a path")
        elif a.startswith("-"):
            die("unknown option: %s" % a)
        elif root is None:
            root = a
        else:
            die("unexpected argument: %s" % a)
        i += 1
    if root is None:
        root = os.path.join(HERE, "..", "..")
    sys.exit(check_repo(os.path.abspath(root), vocab_p, allow_p))
