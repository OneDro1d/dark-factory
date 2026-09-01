#!/usr/bin/env python3
"""df-preflight — probe the machine a mission is about to run on. Learn, don't assume.

WHY THIS EXISTS
---------------
Every recorded fact about a machine decays: repos move, gh accounts get logged out,
branches drift, bearer tokens expire, a lane that existed last month is gone. Drift
cannot be eliminated, only detected — so the preflight PROBES rather than asserts, and
what it learns is written back so the next run starts from a truer baseline.

Four drifts were live on one deployment when this was written, all against files that
looked authoritative:
  - the repo manifest declared a workspace path that did not exist on this machine
    (neither recorded candidate did).
  - a required git-hosting identity was not logged in locally, though the push
    procedure required it — and its failure mode is a 404 that reads as "repo does
    not exist" rather than "wrong identity".
  - a tracked repo was on a feature branch, not the branch declared in the manifest.
  - a binding table pointed at a path recorded on one machine, while the actual
    checkout for that lane lived at a different absolute path on another machine.

PURE / EFFECT SPLIT (deliberate)
--------------------------------
`--report` is PURE: it reads, probes, and prints JSON. It never writes, never mutates
auth, never switches a branch. `--apply <report.json>` is the only effectful mode, and
it writes ONLY entries the caller marked `confirmed: true`.

That split exists so CONFIRMATION lives in the conversation, not in this script. The
interactive `/df-mission` phase runs `--report`, shows you the drift and the proposals,
you say which are right, and only then does the agent call `--apply`. A bash prompt
cannot ask a good question; you can.

The headless supervisor runs `--report` and NEVER applies. There is nobody there to
confirm, and a loop that silently self-heals its own map is a loop that will confidently
work in the wrong directory for six hours.

⚠️ CORRECTED 2026-09-01: this paragraph used to say the supervisor "REFUSES TO START on
drift". It no longer does — drift is INFORMATIONAL there (operator decision, after four
outside installers found that a fresh machine drifts by construction and so could never
reach the kit's own worked example). What has NOT changed is the half that matters here:
the supervisor still never calls `--apply`. Curation is an install-time act performed by a
human who confirmed it, which is why the not-cloned-here case carries a proposal rather
than being fixed automatically.

THREE-STATE VERDICTS — never collapse UNKNOWN into FALSE
--------------------------------------------------------
Every probe returns `ok`, `drift`, or `unknown`:
  ok      — probed, and reality matches what was recorded.
  drift   — probed, and reality DIFFERS. A positive negative. May carry a proposal.
  unknown — could not probe (binary missing, network down, timeout). NOT a failure of
            the thing being probed.
Collapsing `unknown` into `drift` is the bug that writes "no checkout on this machine"
into a lockfile because the network blipped. Only a positive `drift` may block a mission
or justify a write.

IDENTITY OVER LOCATION
----------------------
A repo is identified by its origin remote, never by its directory name. Directory names
drift (a checkout gets cloned or renamed under a new local name); the remote does not.
So when a recorded path is
gone, the search scans the code root for a git worktree whose origin matches the expected
remote. A unique match becomes a proposal. Zero or several become a question for you —
never a guess.

Exit codes (--report):
  0  every probe ok
  1  at least one positive drift
  2  no drift, but at least one probe returned unknown

Usage:
  df-preflight.py --report [--profile <profile>] [--json out.json]
  df-preflight.py --apply report.json
Env:
  LOOM_LOCK      path to the instance lockfile (else the single instances/*/loom.lock.json)
  NOTEPAD        notepad root (default: the repo this script lives in)
"""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

# TWO ROOTS, and conflating them is what made this gate over-broad.
#
#   KIT_ROOT — where this script (and, if present, an instance lockfile) live. Supplies
#              machine facts: codeRoot, codeLayout, probed.*, scope.
#   NOTEPAD  — the objective's notepad, DISCOVERED BY WALKING UP FROM CWD. Supplies
#              repos.manifest.json, i.e. WHICH REPOS THIS MISSION IS ABOUT.
#
# Before this split both came from the script's own location, so every mission was scoped
# to the kit's own manifest. Consequence, observed once in practice: a mission for one
# tracked repo was blocked by branch drift in a repo it never touches. A gate that blocks
# on irrelevant drift gets switched off, and then it protects nothing.
#
# One notepad per objective is the existing doctrine, and each notepad's manifest already
# lists exactly the repos it drives — so the scope needs no new tagging, only the right
# root. Walking up from $PWD is also what the dispatch tooling already does, so this is
# the house convention rather than a new one.
#
# KIT_ROOT is two levels up from this script: the engine ships under boot-kit/scripts/
# within whatever kit/repo installs it, and KIT_ROOT is that kit/repo's own root.
KIT_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def find_notepad(start=None):
    """Nearest ancestor of CWD holding repos.manifest.json. Returns (path, how).

    NOTES.md alone is not enough to claim notepad-hood here: this probe needs the manifest,
    and a directory with notes but no manifest would silently scope the mission to nothing.
    """
    env = os.environ.get("NOTEPAD")
    if env:
        return os.path.abspath(env), "NOTEPAD env"
    d = os.path.abspath(start or os.getcwd())
    while True:
        if os.path.isfile(os.path.join(d, "repos.manifest.json")):
            return d, "discovered from cwd"
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    # Falling back to the kit is honest but must be VISIBLE — it means the mission is
    # scoped to the kit's own repos, which is right only when that is the notepad.
    return KIT_ROOT, "FALLBACK — no notepad above cwd, scoped to the kit root"


NOTEPAD, NOTEPAD_SRC = find_notepad()

# Binaries a mission may need. `required` ones make the machine unusable when absent;
# the rest are reported as `unknown` capability, not as failure -- a machine with no
# `az` is fine for a mission that never touches Azure and broken for one that does.
BINARIES = {
    "git": True, "gh": True, "jq": True, "python3": True, "curl": True,
    "az": False, "kubectl": False, "claude": True, "node": False, "docker": False,
}

SEARCH_MAX_DEPTH = 3          # how deep under codeRoot to hunt for a moved worktree
PROBE_TIMEOUT = 12            # seconds, per network probe


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def run(cmd, timeout=15, env=None):
    """(rc, stdout, stderr). rc=None means the probe itself could not run -> unknown.

    `env` is an OVERLAY on os.environ, not a replacement: a probe that needs one extra
    variable must not lose PATH and HOME to get it.
    """
    try:
        e = None
        if env:
            e = dict(os.environ)
            e.update(env)
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=e)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except FileNotFoundError:
        return None, "", "binary not found"
    except subprocess.TimeoutExpired:
        return None, "", "timed out after %ds" % timeout
    except Exception as e:                                   # never let a probe crash the run
        return None, "", str(e)


def norm_remote(url):
    """github URL -> `owner/repo`, so ssh/https/.git variants compare equal."""
    if not url:
        return ""
    u = url.strip()
    u = re.sub(r"^git@github\.com:", "", u)
    u = re.sub(r"^https?://(www\.)?github\.com/", "", u)
    u = re.sub(r"\.git$", "", u)
    return u.strip("/").lower()


def finding(check, target, verdict, detail, expected=None, actual=None, proposal=None):
    """One probe result. `proposal` is a suggested lockfile write, never auto-applied."""
    f = {"check": check, "target": target, "verdict": verdict, "detail": detail}
    if expected is not None:
        f["expected"] = expected
    if actual is not None:
        f["actual"] = actual
    if proposal:
        f["proposal"] = proposal          # {"path": "lock.codeLayout.<lane>", "value": ...}
    return f


def load_json(path):
    with open(path) as fh:
        return json.load(fh)


def find_lock():
    """Which lockfile describes THIS machine. Returns (path, note).

    LOOM_LOCK wins. Otherwise EVERY candidate is considered -- the repo-root lockfile and
    each instances/*/loom.lock.json -- and the one whose "machine" block matches this
    machine is chosen.

    FIXED once in practice: the rule used to be "the single instances/*/loom.lock.json",
    which is unambiguous only on a machine whose lockfile lives there. One machine's
    lockfile was instead the repo ROOT one (the installer's convention), so the old rule
    silently resolved to a DIFFERENT machine's lockfile and reported that machine's paths
    as local drift -- several drifts, all spurious, and the supervisor refuses to start on
    drift. The installer and this script disagreed about which file describes the machine;
    now they agree.

    Not keyed on hostname on purpose: an ephemeral pod's hostname changes on every
    restart, so a hostname key would look stable and silently stop matching. platform +
    home are stable across restarts of the same machine.

    "machine" is deliberately NOT derived from anything this script probes. Whether codeRoot
    exists would have been a cheaper discriminator, but then drift in codeRoot would silently
    re-select a different machine's lockfile -- the measurement would share a channel with
    its subject.

    No match is NOT a guess: returns (None, why) so the caller reports it, because "I could
    not tell which machine this is" is not a fact about the machine.
    """
    env = os.environ.get("LOOM_LOCK")
    if env:
        return env, None
    # KIT_ROOT, not NOTEPAD: the lockfile describes the MACHINE and lives with the kit.
    # A mission launched from any notepad still needs this machine's codeLayout.
    cands = []
    root = os.path.join(KIT_ROOT, "loom.lock.json")
    if os.path.isfile(root):
        cands.append(root)
    d = os.path.join(KIT_ROOT, "instances")
    if os.path.isdir(d):
        cands += [os.path.join(d, n, "loom.lock.json") for n in sorted(os.listdir(d))
                  if os.path.isfile(os.path.join(d, n, "loom.lock.json"))]
    if not cands:
        return None, "no loom.lock.json under %s" % KIT_ROOT
    if len(cands) == 1:
        return cands[0], None

    me = {"platform": platform.system(), "home": os.path.expanduser("~")}
    matched, undeclared = [], []
    for c in cands:
        try:
            m = (load_json(c) or {}).get("machine") or {}
        except Exception:
            continue
        if not m:
            undeclared.append(c)
        elif all(m.get(k) == v for k, v in me.items()):
            matched.append(c)

    def rel(x):
        return os.path.relpath(x, KIT_ROOT)

    if len(matched) == 1:
        return matched[0], None
    if matched:
        return None, ("%d lockfiles claim machine %s:%s (%s) -- set LOOM_LOCK"
                      % (len(matched), me["platform"], me["home"],
                         ", ".join(rel(x) for x in matched)))
    return None, ("no lockfile declares machine %s:%s -- %d candidate(s), %d with no "
                  "machine block (%s). Set LOOM_LOCK, or add a machine block."
                  % (me["platform"], me["home"], len(cands), len(undeclared),
                     ", ".join(rel(x) for x in cands)))


# ---------------------------------------------------------------------------
# P1 — binaries
# ---------------------------------------------------------------------------

def probe_binaries():
    out = []
    for name, required in sorted(BINARIES.items()):
        path = shutil.which(name)
        if path:
            out.append(finding("bin", name, "ok", path))
        elif required:
            out.append(finding("bin", name, "drift", "required binary not on PATH"))
        else:
            out.append(finding("bin", name, "unknown",
                               "optional binary absent — capability unavailable, not broken"))
    return out


# ---------------------------------------------------------------------------
# P2 — github identities, probed per repo rather than assumed
# ---------------------------------------------------------------------------

def repo_name(repo):
    """A stable label for a manifest entry, whichever schema it uses.

    TWO SCHEMAS may be live across a fleet of notepads:
      NEW — {name, paths: {machine: path}, remote: "owner/repo"}
      OLD — {path: "<some machine's home>/Code/…", remote: "https://github.com/…"}
    The old form carries ONE absolute path baked in for whatever machine wrote it —
    a machine-shaped constant in a file every machine reads is a lie on all but one of
    them. So on any OTHER machine, an old-schema manifest resolves to nothing by path,
    and the origin-remote search is the only thing that finds those repos at all.
    """
    n = repo.get("name")
    if n:
        return n
    rem = norm_remote(repo.get("remote"))
    if rem:
        return rem.split("/")[-1]
    p = repo.get("path") or ""
    return os.path.basename(p.rstrip("/")) or "<unnamed>"


def repo_candidates(repo):
    """Every path this entry offers, newest schema first. Order is preference."""
    out = []
    for key, p in (repo.get("paths") or {}).items():
        out.append(("manifest:" + key, p))
    if repo.get("path"):
        out.append(("manifest:path", repo["path"]))
    return out


def excluded_repo(scope, repo):
    """Is this manifest repo deliberately out of scope on this instance?

    EXPLICIT, by name, from the lockfile — not inferred from a substring appearing
    somewhere in a remote (e.g. excluding on 'core' would also silently swallow a repo
    literally named `hardcore-utils`). An inferred exclusion is a rule nobody can audit,
    and it silently widens the day someone names an unrelated repo that happens to match.
    """
    return repo_name(repo) in (scope.get("excludedRepos") or [])


def probe_github(manifest, scope):
    out = []
    rc, so, se = run(["gh", "auth", "status"], timeout=20)
    if rc is None:
        return [finding("gh", "auth", "unknown", "could not run gh: %s" % se)]

    accounts = re.findall(r"account (\S+)", so + "\n" + se)
    active = re.search(r"account (\S+).*?\n\s*- Active account: true", so + "\n" + se, re.S)
    active_name = active.group(1) if active else (accounts[0] if accounts else "?")
    out.append(finding("gh", "accounts", "ok" if accounts else "drift",
                       "logged in: %s (active: %s)" % (", ".join(accounts) or "none", active_name),
                       actual=accounts))

    # The real question is not "is gh logged in" but "can THIS identity resolve THAT repo".
    # A repo owned by an org your ACTIVE identity is not a member of returns a 404, which
    # reads as "the repo does not exist" rather than "you are the wrong person".
    for repo in manifest.get("repos", []):
        remote = norm_remote(repo.get("remote"))
        if not remote:
            continue
        if excluded_repo(scope, repo):
            out.append(finding("gh-repo", remote, "ok",
                               "not probed — excluded by instance scope"))
            continue
        rc, so, se = run(["gh", "repo", "view", remote, "--json", "name"], timeout=25)
        if rc is None:
            out.append(finding("gh-repo", remote, "unknown", "probe could not run: %s" % se))
        elif rc == 0:
            out.append(finding("gh-repo", remote, "ok", "resolvable as %s" % active_name))
        else:
            # FIXED once in practice. Two bugs met here and produced a false drift that
            # would have blocked every unattended start on the one machine that CAN reach
            # this repo:
            #   1. `owner not in accounts` compared a lowercased owner (norm_remote lowers)
            #      against gh's cased account names, so an account logged in right there
            #      in the line above was reported as "not among the logged-in gh
            #      accounts". The hint asserted the exact opposite of the truth.
            #   2. A 404 as the ACTIVE identity was final. The question this probe exists to
            #      answer is "can THIS MACHINE reach that repo", and a machine holding the
            #      owner's credentials can.
            # So: retry as the owning identity, borrowing its token through the environment.
            # NOT `gh auth switch` — that mutates global state, and --report is pure.
            # WHICH IDENTITY OWNS THIS REPO? Ask the MANIFEST first, and only then guess.
            #
            # This used to be `owner = remote.split("/")[0]` alone — the identity was
            # inferred from the ORG NAME and matched against logged-in account names. That
            # holds only while org == account. It is true for `Michal-Bacia_eso` and false
            # for every org whose name is not also a username: `eso-development` is
            # reachable ONLY as `Michal-Bacia_eso`, so the probe reported a repo the machine
            # can reach perfectly well as DRIFT — and per df-supervisor.sh the supervisor
            # treated drift as fatal when this was written, so one wrong guess here blocked
            # every unattended
            # mission on that lane.
            #
            # The manifest already carries the answer, per-repo, in `account`. It was simply
            # never read. ⚠️ THIS IS THE SAME CLASS AS THE IDENTITY FINDING IN THE
            # OUTSIDE-INSTALLER REPORT (24-27 Aug 2026, finding 07): establish identity from
            # the record that declares it, never from a value that merely looks like it.
            # There the offender was a Slack lookup returning the caller; here it is an org
            # name doubling as a username. Both fail by AGREEING with a plausible guess.
            owner = remote.split("/")[0]
            declared = (repo.get("account") or "").strip()
            owner_acct = next((a for a in accounts if a.lower() == declared.lower()), None) if declared else None
            if owner_acct is None:
                owner_acct = next((a for a in accounts if a.lower() == owner.lower()), None)
            resolved_as = None
            if owner_acct and owner_acct != active_name:
                trc, tso, _ = run(["gh", "auth", "token", "--user", owner_acct], timeout=15)
                if trc == 0 and tso:
                    # tso is a CREDENTIAL: it goes into the child env and nowhere else —
                    # never into a finding, which is written to disk and read aloud.
                    rc2, _, se2 = run(["gh", "repo", "view", remote, "--json", "name"],
                                      timeout=25, env={"GH_TOKEN": tso})
                    if rc2 == 0:
                        resolved_as = owner_acct
                    else:
                        se = se2 or se
            if resolved_as:
                out.append(finding("gh-repo", remote, "ok",
                                   "resolvable as %s (NOT as the active %s) — switch "
                                   "identity before any push, and switch back"
                                   % (resolved_as, active_name)))
            else:
                hint = ""
                if not owner_acct:
                    # Name the account the MANIFEST asked for when there is one. "`eso-development`
                    # is not among the logged-in accounts" sends the reader to look for an account
                    # by that name, which will never exist — the org is not a user. The actionable
                    # sentence is which declared identity is missing.
                    if declared:
                        hint = (" — this repo declares account `%s`, which is not among the "
                                "logged-in gh accounts, so this 404 means WRONG IDENTITY, not "
                                "missing repo (`gh auth login` as %s)" % (declared, declared))
                    else:
                        hint = (" — `%s` is not among the logged-in gh accounts and the manifest "
                                "declares no `account` for this repo, so this 404 most likely "
                                "means WRONG IDENTITY, not missing repo. Declaring the account "
                                "in the manifest entry is what makes this checkable" % owner)
                elif owner_acct != active_name:
                    hint = (" — nor as `%s`, which IS logged in, so this is not merely an "
                            "identity mix-up" % owner_acct)
                out.append(finding("gh-repo", remote, "drift",
                                   "not resolvable as %s%s" % (active_name, hint),
                                   expected="resolvable", actual=se.splitlines()[:1]))
    return out


# ---------------------------------------------------------------------------
# P3 — cloud / cluster
# ---------------------------------------------------------------------------

def probe_machine(lock, lock_path):
    """Does this lockfile's `machine` block actually describe THIS machine?

    WHY THIS PROBE EXISTS. The block is read by find_lock() to disambiguate several candidate
    lockfiles — and ONLY then: `if len(cands) == 1` returns before the comparison. A personal
    kit has exactly one lockfile, so on a kit the block is never consulted and a wrong value
    sits there indefinitely, correct-looking.

    Measured 2026-09-01 on the shipped ESO kit: `home` is `__HOME_DIR__` and `codeRoot` is
    `__CODE_ROOT__`, while `platform` is the literal string "Darwin".

    ⚠️ CORRECTED. AN EARLIER VERSION OF THIS DOCSTRING CALLED ALL THREE A DEFECT AND SAID
    "nothing said so". THAT WAS WRONG, and the correction is kept rather than quietly
    deleted. The kit ships `home` and `codeRoot` blank ON PURPOSE and documents it twice:
    START-HERE has a titled step, "Fill in the two placeholders", with a script; and the
    README's "What is deliberately absent" gives the reason — shipping the building machine's
    real values "would make your instance quietly claim to be someone else's laptop — a wrong
    value that reads exactly like a right one". That is the right instinct, well argued, and
    this probe SERVES it: it says the step has not been done on THIS machine, rather than
    leaving that to a document the reader may not have reached.

    THE ACTUAL DEFECT IS NARROWER, AND THE KIT'S OWN PRINCIPLE CONVICTS IT. `machine.platform`
    ships FILLED, with the building machine's value, while its two siblings ship loudly blank.
    That is exactly the wrong-value-that-reads-right case the README warns about, and it is
    the one field the docs never mention. On a Linux workspace, a kit built on a Mac claims to
    be a Mac, silently.

    The README also says "lock-verify reads neither, so the kit still installs LOCKED as
    shipped — the honesty costs nothing." True of lock-verify. NOT true of this file:
    find_lock() matches on platform+home. The cost is zero only while exactly one lockfile
    exists, which is why it has been zero so far.

    ⚠️ THE OUTSIDE REPORT CALLED THIS DORMANT AND IT IS NOT. Its words were "no tool reads
    that field today, which is the only reason it went unnoticed". A tool does read it; the
    single-candidate fast path is what hid it. The distinction matters because the failure is
    LATENT, not absent: the moment a kit gains a second instance lockfile — which is exactly
    what the Coder workspaces do, `instances/<name>/loom.lock.json` — the match runs, nothing
    matches, and preflight cannot resolve a lockfile at all. Both fields are wrong, so the
    block matches nothing on any machine, including the one that generated it.

    Reported UNKNOWN, not drift: a machine block that disagrees with this machine may simply
    describe a different machine, which is the whole point of having one. What is being said
    is "this was never verified here", and an unsubstituted placeholder is said separately
    because it is not a disagreement — it is a value nobody ever supplied.
    """
    out = []
    m = (lock or {}).get("machine") or {}
    if not m:
        return [finding("machine", "block", "unknown",
                        "no `machine` block in %s — nothing to check this lockfile against. "
                        "Harmless while one lockfile exists here; the day a second appears, "
                        "find_lock cannot tell them apart." % (lock_path or "the lockfile"))]

    me = {"platform": platform.system(), "home": os.path.expanduser("~")}

    # SCAN THE WHOLE LOCKFILE, not just the machine block. Limiting this to `machine` was the
    # first draft and it missed the worst instance: the same ESO kit carries
    # codeRoot="__CODE_ROOT__", so EVERY repo probe searches a directory that does not exist
    # and reports every repo as not-on-this-machine. A check scoped to the block where the
    # bug was first noticed finds that bug and no other one of the same kind.
    def scan(node, path=""):
        hits = []
        if isinstance(node, dict):
            for k, v in node.items():
                if k.startswith("$"):      # commentary, and templates legitimately quote them
                    continue
                hits += scan(v, "%s.%s" % (path, k) if path else k)
        elif isinstance(node, list):
            for i, v in enumerate(node):
                hits += scan(v, "%s[%d]" % (path, i))
        elif isinstance(node, str) and len(node) > 4 \
                and node.startswith("__") and node.endswith("__"):
            hits.append((path, node))
        return hits

    placeholders = sorted(scan(lock or {}))
    if placeholders:
        out.append(finding(
            "lockfile", "placeholders", "unknown",
            "%d value(s) are still the shipped placeholder: %s. These are DELIBERATELY blank "
            "in a kit — filling them from the building machine would make this instance "
            "quietly claim to be someone else's laptop — so this is not a defect, it is the "
            "setup step not done yet on THIS machine. See START-HERE, \"Fill in the two "
            "placeholders\"."
            % (len(placeholders), "; ".join("%s=%s" % (p, v) for p, v in placeholders)),
            actual=[p for p, _ in placeholders]))
    ph_keys = {p.split(".")[-1] for p, _ in placeholders if p.startswith("machine.")}

    mismatched = [(k, m.get(k), v) for k, v in me.items()
                  if k in m and k not in ph_keys and m.get(k) != v]
    if mismatched:
        out.append(finding(
            "machine", "identity", "unknown",
            "this lockfile describes a different machine than the one running: %s. Not drift "
            "— a machine block is allowed to describe another machine. But if this lockfile is "
            "meant to be THIS machine's, the value was baked at generation time and never "
            "corrected. ⚠️ `platform` is the field to look at: a kit ships `home` and codeRoot "
            "loudly blank so you cannot inherit them by accident, and then ships `platform` "
            "FILLED with the building machine's value — the wrong-value-that-reads-right case "
            "the kit's own README warns about, in the one field it never mentions."
            % "; ".join("%s recorded=%r actual=%r" % (k, rec, act)
                        for k, rec, act in mismatched)))
    if not out:
        out.append(finding("machine", "identity", "ok",
                           "%s:%s matches this machine" % (m.get("platform"), m.get("home"))))
    return out


def probe_cloud():
    out = []
    if shutil.which("az"):
        rc, so, se = run(["az", "account", "show", "-o", "json"], timeout=30)
        if rc is None:
            out.append(finding("azure", "account", "unknown", "probe could not run: %s" % se))
        elif rc != 0:
            # UNKNOWN, NOT DRIFT — and the sibling probe fifteen lines below already had this
            # right. `kubectl` with no current context is reported unknown, because a context
            # nobody set is not a machine that has gone wrong. An unauthenticated `az` is the
            # same shape: `az` is an OPTIONAL binary here (see BINARIES), so its presence says
            # somebody installed the CLI, never that this mission needs Azure.
            #
            # Reported as drift, it was UNCLEARABLE on a machine with no Azure tenant to log
            # into, and named nowhere in the kit's access rows — so the only way to make the
            # gate green was to stop reading it. An outside installer hit exactly that
            # (24-27 Aug 2026, finding 04: "our own doctrine, broken by our own tools").
            # Never collapse unknown into drift is written into the kit; this file enforced it
            # for kubectl and broke it for az, one function apart. The rule was understood and
            # unenforced.
            #
            # ⚠️ WHAT THIS GIVES UP: a mission that really does deploy to AKS will now see
            # `unknown` where it once saw `drift`. That is the correct verdict — nothing was
            # probed about whether Azure is REQUIRED — and it stays visible in its own UNKNOWN
            # section. A mission that must have Azure should assert it in that mission's
            # hard-stops, where a human decided it, rather than relying on a fleet-wide probe
            # inferring the requirement from a binary being on PATH.
            out.append(finding("azure", "account", "unknown",
                               "az is installed but not logged in. UNKNOWN, not drift: nothing "
                               "here declares that this machine needs Azure, so this says only "
                               "that the capability is unconfirmed. `az login` if a mission "
                               "needs it."))
        else:
            try:
                a = json.loads(so)
                out.append(finding("azure", "account", "ok",
                                   "%s (%s)" % (a.get("name"), a.get("id")),
                                   actual={"subscription": a.get("name"), "id": a.get("id"),
                                           "tenant": a.get("tenantDisplayName")}))
            except ValueError:
                out.append(finding("azure", "account", "unknown", "az returned unparseable JSON"))

    if shutil.which("kubectl"):
        rc, so, se = run(["kubectl", "config", "current-context"], timeout=15)
        if rc is None:
            out.append(finding("k8s", "context", "unknown", "probe could not run: %s" % se))
        elif rc != 0 or not so:
            out.append(finding("k8s", "context", "unknown", "no current context set"))
        else:
            # Reachability is a SEPARATE question from configuration. A context can be
            # set and the cluster unreachable; reporting only the former is how you learn
            # at iteration 7 that nothing was ever deployable.
            rc2, _, se2 = run(["kubectl", "version", "-o", "json", "--request-timeout=8s"],
                              timeout=20)
            if rc2 == 0:
                out.append(finding("k8s", "context", "ok", "%s — reachable" % so, actual=so))
            else:
                out.append(finding("k8s", "context", "unknown",
                                   "context %s set but API not reachable: %s" % (so, se2[:120]),
                                   actual=so))
    return out


# ---------------------------------------------------------------------------
# P4 — repos: resolve by IDENTITY, search when the recorded path is gone
# ---------------------------------------------------------------------------

def git_worktrees(root, max_depth=SEARCH_MAX_DEPTH):
    """Yield directories under `root` that are git worktrees, breadth-limited."""
    root = os.path.abspath(root)
    base_depth = root.rstrip("/").count("/")
    for dirpath, dirnames, _ in os.walk(root):
        if dirpath.rstrip("/").count("/") - base_depth >= max_depth:
            dirnames[:] = []
        dirnames[:] = [d for d in dirnames if d not in
                       (".git", "node_modules", "vendor", ".venv", "__pycache__")]
        if os.path.exists(os.path.join(dirpath, ".git")):
            yield dirpath
            dirnames[:] = []          # do not descend into a repo looking for repos


def origin_of(path):
    rc, so, _ = run(["git", "-C", path, "remote", "get-url", "origin"], timeout=10)
    return norm_remote(so) if rc == 0 else ""


def probe_repos(manifest, lock, probed, scope):
    out = []
    code_root = lock.get("codeRoot") or os.path.expanduser("~/code")

    # Build the remote -> path index ONCE. Every repo lookup reads it, so a machine with
    # twenty checkouts costs one walk, not twenty.
    index = {}
    by_name = {}          # basename -> [paths], for entries with no remote to match on
    if os.path.isdir(code_root):
        for wt in git_worktrees(code_root):
            by_name.setdefault(os.path.basename(wt).lower(), []).append(wt)
            o = origin_of(wt)
            if o:
                index.setdefault(o, []).append(wt)
    else:
        out.append(finding("repo-root", code_root, "drift", "codeRoot does not exist"))

    for repo in manifest.get("repos", []):
        name = repo_name(repo)
        if excluded_repo(scope, repo):
            out.append(finding("repo", name, "ok",
                               "absent BY POLICY — excluded by instance scope, not a gap"))
            continue
        want = norm_remote(repo.get("remote"))

        # THIRD SCHEMA VARIANT: some manifests carry only a path, no remote at all.
        # Identity-by-remote is then impossible, and the honest verdict is UNKNOWN — not
        # `drift`. Claiming "not found on this machine" for a repo whose identity we
        # simply cannot check is the exact unknown-collapsed-into-false error this tool
        # exists to avoid: it would report a whole set of healthy checkouts as missing.
        if not want:
            # Search the worktree index by BASENAME, not a guessed path: repos sit under
            # their lane (e.g. <codeRoot>/<lane>/<repo-name>), not directly under
            # codeRoot, so joining codeRoot + name finds nothing and reports a false blank.
            hits = by_name.get(name.lower(), [])
            if len(hits) == 1:
                out.append(finding(
                    "repo", name, "unknown",
                    "manifest declares no remote, so identity CANNOT be verified. One "
                    "worktree with a matching NAME exists at %s — a name match is a hint, "
                    "not proof. Add a `remote` to the manifest to make this checkable." % hits[0],
                    actual=hits[0],
                    proposal={"path": "probed.repos.%s.path" % name, "value": hits[0]}))
            elif len(hits) > 1:
                out.append(finding(
                    "repo", name, "unknown",
                    "manifest declares no remote and %d worktrees share this name — "
                    "ambiguous, will not guess: %s" % (len(hits), ", ".join(hits)),
                    actual=hits))
            else:
                out.append(finding(
                    "repo", name, "unknown",
                    "manifest declares no remote and no name-matching worktree under %s — "
                    "nothing here can be verified either way" % code_root))
            continue

        candidates = []

        # Resolution order mirrors repos.manifest.json $resolution: explicit beats
        # inferred, and a previously CONFIRMED probe beats the shipped candidate list.
        env = os.environ.get("LOOM_REPO_" + re.sub(r"\W", "_", (name or "")).upper())
        if env:
            candidates.append(("env", env))
        rec = (probed.get("repos") or {}).get(name, {}).get("path")
        if rec:
            candidates.append(("learned", rec))
        candidates.extend(repo_candidates(repo))

        resolved = None
        tried = []
        for src, p in candidates:
            tried.append("%s=%s" % (src, p))
            if os.path.isdir(p) and origin_of(p) == want:
                resolved = (src, p)
                break

        if resolved:
            src, path = resolved
            verdict, detail = "ok", "%s (via %s)" % (path, src)
            # A resolved repo can still be on the wrong branch -- reported, never changed.
            rc, so, _ = run(["git", "-C", path, "branch", "--show-current"], timeout=10)
            want_branch = repo.get("branch")
            if rc == 0 and want_branch and so and so != want_branch:
                verdict = "drift"
                detail = ("%s is on branch `%s`, manifest declares `%s`" % (path, so, want_branch))
                out.append(finding("repo-branch", name, verdict, detail,
                                   expected=want_branch, actual=so))
                verdict, detail = "ok", "%s (via %s)" % (path, src)
            out.append(finding("repo", name, verdict, detail, expected=want, actual=path,
                               proposal=None if src in ("env", "learned")
                               else {"path": "probed.repos.%s.path" % name, "value": path}))
            continue

        # Recorded location is gone. Hunt by IDENTITY (origin remote), not by name.
        hits = index.get(want, [])
        if len(hits) == 1:
            out.append(finding(
                "repo", name, "drift",
                "no recorded path resolved (tried: %s) — found one checkout with the "
                "expected origin at %s" % ("; ".join(tried) or "none", hits[0]),
                expected=want, actual=hits[0],
                proposal={"path": "probed.repos.%s.path" % name, "value": hits[0]}))
        elif len(hits) > 1:
            out.append(finding(
                "repo", name, "drift",
                "no recorded path resolved and %d checkouts share the origin %s — "
                "ambiguous, will not guess: %s" % (len(hits), want, ", ".join(hits)),
                expected=want, actual=hits))
        else:
            # SELF-CURATION. A kit ships a manifest naming the repos its ESTATE drives; a
            # fresh machine has cloned none of them yet. So on a first install every one of
            # these was drift, drift blocked the supervisor, and the kit's own worked example
            # — the one step that proves the loop — was unreachable. Two outside installers
            # hit this independently and both reached the same repair by hand: curate the
            # manifest to your own lane. A repair two strangers reach without talking is the
            # shipped default (feedback 24-27 Aug 2026, finding 01; operator decision
            # 2026-09-01: ship self-curating).
            #
            # THE VERDICT STAYS `drift`, DELIBERATELY. Zero worktrees found IS a probe that
            # ran and returned a positive answer about the world, which is exactly what
            # `drift` means here; `unknown` is for a probe that could not run. Relabelling it
            # would also make it unappliable — apply_report refuses unknown findings on
            # principle — so the honest verdict and the useful one are the same verdict.
            #
            # ⚠️ CURATION IS AN INSTALL-TIME ACT, NEVER A LOOP-TIME ONE. This only PROPOSES.
            # `--apply` writes it, and the supervisor never calls `--apply`: a loop that
            # rewrites its own map works confidently in the wrong directory for six hours.
            out.append(finding(
                "repo", name, "drift",
                "not on this machine — no worktree under %s has origin %s (tried: %s). "
                "If this estate repo simply is not cloned here, curate it out of scope: "
                "confirm the proposal and run --apply. Clone it later and remove the name "
                "from scope.excludedRepos."
                % (code_root, want, "; ".join(tried) or "none"),
                expected=want, actual=None,
                proposal={"path": "scope.excludedRepos", "value": name, "op": "append"}))
    return out


# ---------------------------------------------------------------------------
# P5 — the per-lane code map (codeLayout)
# ---------------------------------------------------------------------------

def probe_layout(lock):
    """A lane is a path, an absolute path, or JSON null meaning 'no checkout here'.

    null must render as the WORDS `none on this machine` and never as a path. A wrong
    map gets trusted, and a fabricated path is worse than a blank.

    The set of lanes is NOT hardcoded here: which lanes exist is a Tier-2/3 fact (each
    org names its own), so this engine reads whatever keys the lockfile's own
    `codeLayout` declares, sorted for stable output, rather than assuming any fixed set.

    TWO THINGS THAT LOOK LIKE NOTHING AND ARE NOT (fixed on review of the import):

    1. Iterating the declared keys means a lockfile that declares NO codeLayout emits NO
       findings at all. Reading whatever is declared is right; reporting SILENCE when
       nothing is declared is not. "No lanes were declared" is a fact worth one `unknown`
       line -- absence has no shared path, so nothing else in this probe would ever say it.
       An empty section and a healthy one must not look identical in the report.

    2. `$`-prefixed keys are prose, not lanes. The house convention is that any JSON key
       starting with `$` is a comment for the human reading the file. Without this skip a
       lockfile carrying `codeLayout.$comment` gets that comment treated as a directory
       name, joined onto codeRoot, found missing, and reported as DRIFT -- a fabricated
       finding from a file that is completely correct, and one that would block a
       supervisor start. Verified against a real lockfile carrying such a comment.
    """
    out = []
    code_root = lock.get("codeRoot") or ""
    layout = lock.get("codeLayout") or {}
    lanes = sorted(k for k in layout.keys() if not k.startswith("$"))
    if not lanes:
        out.append(finding("lane", "codeLayout", "unknown",
                           "no lanes declared in codeLayout -- this probe cannot say "
                           "where any lane lives on this machine. Not a finding about "
                           "the machine: a gap in the record."))
        return out
    for lane in lanes:
        val = layout[lane]
        if val is None:
            out.append(finding("lane", lane, "ok", "none on this machine (declared null)"))
            continue
        path = val if val.startswith("/") else os.path.join(code_root, val)
        if os.path.isdir(path):
            out.append(finding("lane", lane, "ok", path, actual=path))
        else:
            out.append(finding("lane", lane, "drift",
                               "declared `%s` -> %s which does not exist" % (val, path),
                               expected=path))
    return out


# ---------------------------------------------------------------------------
# P6 — MCP hubs: a LIVE call, not the presence of a header
# ---------------------------------------------------------------------------

def expand_env(value):
    """Expand ${VAR} / $VAR. Returns (expanded, [names that were UNSET]).

    THE FINDING THAT FORCED THIS: some MCP hub entries in ~/.claude.json do not hold
    tokens at all -- they hold `Bearer ${SOME_TOKEN_VAR}`, which Claude Code expands from
    the environment at launch. A first cut of this probe posted the literal template and
    got 401 "invalid token format" from every such hub, i.e. it reported total drift on a
    machine whose hubs were answering fine.

    That is not a cosmetic bug. It means HUB AUTH IS INHERITED FROM THE ENVIRONMENT, so a
    headless `claude -p` reaches a hub only if the env var its header references is
    present in the process that spawned it. A supervisor started from a stripped
    environment produces children that boot cleanly, fail every write, and keep looping.
    Checking that those variables are SET is therefore a first-class preflight check,
    not a detail.
    """
    missing = []

    def sub(m):
        name = m.group(1) or m.group(2)
        val = os.environ.get(name)
        if val is None:
            missing.append(name)
            return m.group(0)
        return val

    return re.sub(r"\$\{(\w+)\}|\$(\w+)", sub, value or ""), missing


def probe_mcp(profile=None, scope=None):
    """Bearer tokens expire. A header that exists proves nothing; a tools/list does.

    Never prints the token -- only the env var NAME it came from, and the transport
    status. Names are not secrets; values never leave this function.
    """
    out = []
    cfg_path = os.path.expanduser("~/.claude.json")
    try:
        cfg = load_json(cfg_path)
    except Exception as e:
        return [finding("mcp", cfg_path, "unknown", "could not read config: %s" % e)]

    servers = cfg.get("mcpServers") or {}
    if not servers:
        return [finding("mcp", "mcpServers", "drift", "no MCP servers configured in %s" % cfg_path)]

    for name, s in sorted(servers.items()):
        if profile and not name.startswith(profile):
            continue
        url = s.get("url")
        auth = (s.get("headers") or {}).get("Authorization")
        if not url:
            out.append(finding("mcp", name, "unknown", "no url (transport %s)" % s.get("type")))
            continue
        if not auth:
            out.append(finding("mcp", name, "drift", "no Authorization header configured"))
            continue

        auth, unset = expand_env(auth)
        if unset:
            # Report and STOP for this hub: posting an unexpanded template yields a 401
            # that would be indistinguishable from a revoked token.
            out.append(finding(
                "mcp-env", name, "drift",
                "auth references %s, which is UNSET in this environment — the hub is "
                "probably fine; this process (and any headless child it spawns) cannot "
                "authenticate to it" % ", ".join("$" + u for u in unset),
                expected="env var set", actual=unset))
            continue

        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode()
        req = urllib.request.Request(url, data=body, method="POST", headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Authorization": auth,
        })
        try:
            with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT) as r:
                raw = r.read().decode("utf-8", "replace")
            n = raw.count('"name"')
            out.append(finding("mcp", name, "ok", "live — tools/list returned ~%d entries" % n,
                               actual=url))
        except urllib.error.HTTPError as e:
            verdict = "drift" if e.code in (401, 403, 404) else "unknown"
            note = " (token expired or revoked)" if e.code in (401, 403) else ""
            out.append(finding("mcp", name, verdict, "HTTP %s%s" % (e.code, note), actual=url))
        except Exception as e:
            # Network failure is UNKNOWN. The hub may be perfectly healthy.
            out.append(finding("mcp", name, "unknown", "unreachable: %s" % e, actual=url))

    # Absence of a whole estate's hub is a finding only where that estate is actually in
    # scope for THIS deployment, and which estates exist at all is a Tier-2/3 fact this
    # engine does not hardcode. A profile-specific wrapper that DOES know its estate names
    # can add that advisory on top of these per-server findings; the shared engine only
    # reports what it can observe about the servers actually configured.
    return out


# ---------------------------------------------------------------------------
# report / apply
# ---------------------------------------------------------------------------

def build_report(profile):
    findings, notes = [], []

    lock_path, lock_note = find_lock()
    if lock_note:
        notes.append(lock_note)
    if not lock_path or not os.path.isfile(lock_path):
        notes.append("no instance lockfile resolved (set LOOM_LOCK) — layout and repo "
                     "checks run with defaults and cannot be persisted")
        lock = {}
    else:
        try:
            lock = load_json(lock_path)
        except Exception as e:
            notes.append("lockfile %s unreadable: %s" % (lock_path, e))
            lock = {}

    man_path = os.path.join(NOTEPAD, "repos.manifest.json")
    try:
        manifest = load_json(man_path)
    except Exception as e:
        manifest = {"repos": []}
        notes.append("repos.manifest.json unreadable (%s) — repo checks skipped" % e)

    probed = lock.get("probed") or {}
    scope = lock.get("scope") or {}

    # A profile the operator EXCLUDED is refused here, before a single probe runs. This
    # is not a drift to be repaired: the answer to "a given profile's hub is missing" on
    # a machine that has excluded it is "correct, and it stays missing". Refusing early
    # also means the mission never gets far enough to half-configure itself against the
    # wrong estate.
    excluded = scope.get("excluded") or {}
    if profile and profile in excluded:
        findings.append(finding("scope", profile, "drift",
                                "REFUSED — %s" % excluded[profile]))
        return {"generatedAt": now(), "notepad": NOTEPAD, "lockfile": lock_path,
                "profile": profile, "refused": True,
                "summary": {"ok": 0, "drift": 1, "unknown": 0},
                "notes": notes, "findings": findings}
    if profile and scope.get("estates") and profile not in scope["estates"]:
        notes.append("profile %r is not in this instance's declared estates %s — probing "
                     "anyway, but nothing here was set up for it"
                     % (profile, scope["estates"]))

    findings += probe_binaries()
    findings += probe_machine(lock, lock_path)
    findings += probe_github(manifest, scope)
    findings += probe_cloud()
    findings += probe_repos(manifest, lock, probed, scope)
    findings += probe_layout(lock)
    findings += probe_mcp(profile, scope)

    drift = [f for f in findings if f["verdict"] == "drift"]
    unknown = [f for f in findings if f["verdict"] == "unknown"]
    return {
        "generatedAt": now(),
        "notepad": NOTEPAD,
        "notepadSource": NOTEPAD_SRC,
        "kitRoot": KIT_ROOT,
        "lockfile": lock_path,
        "profile": profile,
        "summary": {"ok": len(findings) - len(drift) - len(unknown),
                    "drift": len(drift), "unknown": len(unknown)},
        "notes": notes,
        "findings": findings,
        "$applyContract": ("Set `confirmed: true` on a finding whose `proposal` you have "
                           "verified with the operator, then run --apply. Nothing is "
                           "written without that flag. `unknown` findings are NEVER "
                           "applied: an unreachable probe is not a fact about the world."),
    }


def render(report):
    """Human-readable, drift first — the reader's attention goes where the risk is."""
    s = report["summary"]
    # The notepad is printed FIRST because it defines the scope: which repos were checked
    # at all. A reader who cannot see the scope cannot judge whether "ok" means anything.
    lines = ["preflight %s  ok=%d drift=%d unknown=%d"
             % (report["generatedAt"], s["ok"], s["drift"], s["unknown"]),
             "notepad: %s  (%s)" % (report.get("notepad"), report.get("notepadSource")),
             ""]
    for verdict, label in (("drift", "DRIFT"), ("unknown", "UNKNOWN"), ("ok", "ok")):
        group = [f for f in report["findings"] if f["verdict"] == verdict]
        if not group:
            continue
        lines.append("── %s ──" % label)
        for f in group:
            lines.append("  %-10s %-28s %s" % (f["check"], f["target"], f["detail"]))
            if f.get("proposal"):
                lines.append("             ↳ proposes %s = %s"
                             % (f["proposal"]["path"], f["proposal"]["value"]))
        lines.append("")
    for n in report.get("notes", []):
        lines.append("note: " + n)
    return "\n".join(lines)


def apply_report(path):
    """Write ONLY confirmed proposals. Refuses unknown findings on principle."""
    report = load_json(path)
    lock_path = report.get("lockfile") or find_lock()[0]
    if not lock_path or not os.path.isfile(lock_path):
        sys.exit("apply: no lockfile to write to (set LOOM_LOCK)")
    lock = load_json(lock_path)
    probed = lock.setdefault("probed", {})
    probed.setdefault("$comment",
                      "Learned by df-preflight.py and CONFIRMED by the operator. These "
                      "override the shipped candidate lists in repos.manifest.json for "
                      "THIS machine only. Re-probed every mission; stale entries are "
                      "corrected, not trusted.")

    written = []
    for f in report.get("findings", []):
        if not f.get("confirmed"):
            continue
        if f["verdict"] == "unknown":
            print("skip (unknown, never applied): %s/%s" % (f["check"], f["target"]))
            continue
        prop = f.get("proposal")
        if not prop:
            continue
        node = lock
        parts = prop["path"].split(".")
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        # Two shapes, because a curation proposal names a MEMBER of a list, not the list.
        # Without the append op, confirming "exclude repo B" would overwrite the list that
        # already excludes repo A — the second curation silently un-curating the first, on
        # a path whose whole purpose is to accumulate.
        if prop.get("op") == "append":
            cur = node.get(parts[-1])
            if not isinstance(cur, list):
                cur = [] if cur in (None, "") else [cur]
            if prop["value"] in cur:
                print("skip (already present): %s += %s" % (prop["path"], prop["value"]))
                continue
            cur.append(prop["value"])
            node[parts[-1]] = cur
            written.append("%s += %s" % (prop["path"], prop["value"]))
        else:
            node[parts[-1]] = prop["value"]
            written.append("%s = %s" % (prop["path"], prop["value"]))

    if not written:
        print("apply: nothing confirmed — lockfile untouched")
        return
    probed["checkedAt"] = now()
    tmp = lock_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(lock, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, lock_path)
    print("apply: wrote %d entries to %s" % (len(written), lock_path))
    for w in written:
        print("  " + w)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--report", action="store_true", help="probe and print (pure, read-only)")
    ap.add_argument("--apply", metavar="REPORT", help="write confirmed proposals to the lockfile")
    ap.add_argument("--profile", help="restrict MCP probes to hubs with this prefix")
    ap.add_argument("--json", metavar="OUT", help="also write the JSON report here")
    args = ap.parse_args()

    if args.apply:
        apply_report(args.apply)
        return

    report = build_report(args.profile)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=2)
            fh.write("\n")
    print(render(report))
    if report["summary"]["drift"]:
        sys.exit(1)
    if report["summary"]["unknown"]:
        sys.exit(2)


if __name__ == "__main__":
    main()
