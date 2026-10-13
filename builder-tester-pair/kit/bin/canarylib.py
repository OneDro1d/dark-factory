"""canarylib — the tester's leak canaries .

Both agents usually share one account and one shared disk, so no file permission can keep the builder from
the tester's checks. Canaries make a leak DETECTABLE instead: the tester puts unique made-up values (`vgl-<16 hex>`) into
its scenarios. Only the tester's home holds the list. If one ever shows up in the builder's work — a PR diff, a commit
message, the knowledge drafts, the ledger — the builder saw a check, and the PASS is refused and escalated to the owner.

Never print a canary value outside the tester's own session: tools report WHERE a hit is (file, commit), never what.
"""
import os, pathlib, re, secrets, socket, subprocess, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib"))
import pairconf  # noqa: E402
CFG = pairconf.load()
TESTER_HOST = pairconf.get(CFG, "tester.host", "")
HOME_FILE = pathlib.Path(os.path.expanduser(pairconf.get(CFG, "tester.kits_dir", "~/test-kits"))) / ".canaries"
SHAPE = re.compile(r"^vgl-[0-9a-f]{16}$")
# app -> base ref the builder's PR is diffed against (repos[].base in pair.yaml)
BASES = {app: "origin/" + str(r.get("base", "main")) for app, r in pairconf.apps(CFG).items()}
_drafts = pairconf.get(CFG, "paths.knowledge_drafts")
SHARED = [pairconf.ledger_dir(CFG)] + ([pathlib.Path(os.path.expanduser(_drafts))] if _drafts else [])
MAX_FILE = 2_000_000


def _test_file():
    """Tests only: CANARY_TEST_FILE under /tmp (no symlinks) stands in for the tester's list, on any host."""
    p = os.environ.get("CANARY_TEST_FILE")
    if not p:
        return None
    r = pathlib.Path(p)
    if str(r.resolve()).startswith("/tmp/") and not any(x.is_symlink() for x in [r] + list(r.parents)):
        return r
    return None


def canary_file():
    t = _test_file()
    if t:
        return t
    return HOME_FILE if socket.gethostname() == TESTER_HOST else None


def load():
    f = canary_file()
    if not f or not f.exists():
        return []
    return [l.strip() for l in f.read_text().splitlines() if SHAPE.match(l.strip())]


def new():
    f = canary_file()
    if not f:
        raise SystemExit("refused: canaries live only in the tester workspace")
    f.parent.mkdir(parents=True, exist_ok=True)
    v = "vgl-" + secrets.token_hex(8)
    fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a") as h:
        h.write(v + "\n")
    os.chmod(f, 0o600)
    return v


def hits_in_text(text, vals=None):
    """Indexes (1-based, in list order) of canaries found in text — never the values."""
    vals = load() if vals is None else vals
    low = text.lower()
    return [i + 1 for i, v in enumerate(vals) if v in low]


def _scan_tree(root, vals):
    out = []
    if not root.exists():
        return out
    for p in root.rglob("*"):
        try:
            if p.is_file() and not p.is_symlink() and p.stat().st_size <= MAX_FILE:
                idx = hits_in_text(p.read_text(errors="ignore"), vals)
                if idx:
                    out.append(f"{p} (canary #{','.join(map(str, idx))})")
        except OSError:
            pass
    return out


def scan(app, commit):
    """→ (rc, lines). rc 0 = clean, 4 = HIT (possible leak), 2 = not checked (reason in lines)."""
    vals = load()
    if not vals:
        return 2, ["canary: not checked — no canaries yet (the tester: `canary new` and put the value in a scenario)"]
    if app not in BASES or not re.fullmatch(r"[0-9a-f]{7,40}", commit or ""):
        return 2, [f"canary: not checked — unknown app or commit ({app})"]
    src = pathlib.Path.home() / ".cache" / "local-verify" / f"{app}-{commit[:12]}" / "src"
    hits, notes = [], []
    if (src / ".git").exists():
        r = subprocess.run(["git", "-C", str(src), "log", "-p", "--format=commit %H%n%B", f"{BASES[app]}..{commit}"],
                           capture_output=True, text=True)
        if r.returncode == 0:
            cur = None
            for line in r.stdout.splitlines():
                if line.startswith("commit ") and re.fullmatch(r"commit [0-9a-f]{40}", line):
                    cur = line[7:19]
                idx = hits_in_text(line, vals)
                if idx:
                    hits.append(f"PR diff/message, commit {cur} (canary #{','.join(map(str, idx))})")
        else:
            notes.append(f"canary: PR diff not checked — git log {BASES[app]}..{commit[:12]} failed")
    else:
        notes.append(f"canary: PR diff not checked — no local-verify clone for {app}@{commit[:12]} (run local-verify first)")
    for root in SHARED:
        hits += _scan_tree(root, vals)
    if hits:
        return 4, [f"CANARY HIT (possible holdout leak): {h}" for h in sorted(set(hits))]
    return (2 if notes else 0), (notes or [f"canary: clean ({len(vals)} canaries; PR diff + shared ledger/drafts)"])
