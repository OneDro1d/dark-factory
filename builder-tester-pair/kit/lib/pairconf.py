"""pairconf — read pair.yaml, the one settings file for a builder/tester pair.

Every tool in this kit gets names, paths, ids and rules from here; nothing project- or person-specific is
hard-coded. Lookup order for the file:
  1. $PAIR_CONFIG
  2. ./pair.yaml, then each parent folder's pair.yaml (agents start in paths.shared_root, where it lives)
  3. ~/.config/builder-tester-agents/pair.yaml (written by `install.sh` as a pointer copy)

CLI (for shell scripts):  python3 pairconf.py get builder.name
                          python3 pairconf.py role            # builder | tester | unknown, from `hostname`
"""
import json
import os
import pathlib
import socket
import sys

try:
    import yaml  # PyYAML
except ImportError:  # pragma: no cover - JSON is accepted as a fallback
    yaml = None

ROLES = ("builder", "tester")


def find_config():
    env = os.environ.get("PAIR_CONFIG")
    if env:
        return pathlib.Path(env).expanduser()
    here = pathlib.Path.cwd()
    for d in [here, *here.parents]:
        if (d / "pair.yaml").is_file():
            return d / "pair.yaml"
    home = pathlib.Path.home() / ".config" / "builder-tester-agents" / "pair.yaml"
    if home.is_file() or home.is_symlink():
        # install.sh links this to the shared pair.yaml. A link whose target is gone is a pair workspace that lost its
        # settings, not "no pair here": return it, so load() fails and the guards fail closed instead of switching off.
        return home
    return None


def _kit_root():
    """The kit folder, also when this module runs as an installed copy in ~/.claude/hooks: $PAIR_KIT_ROOT, else the
    pointer install.sh writes (~/.config/builder-tester-agents/kit), else this file's own kit."""
    for c in (os.environ.get("PAIR_KIT_ROOT"), pathlib.Path.home() / ".config" / "builder-tester-agents" / "kit"):
        if c and (pathlib.Path(c) / "kit" / "lib" / "pairconf.py").is_file():
            return pathlib.Path(c).resolve()
    return pathlib.Path(__file__).resolve().parents[2]


KIT_ROOT = _kit_root()
CONCAT = {("rules", "standing")}  # lists that ADD to the base file's list instead of replacing it


def merge(base, over, path=()):
    """Deep merge for `extends:` — dicts merge, lists replace (except CONCAT), scalars replace."""
    out = dict(base)
    for k, v in over.items():
        here = path + (k,)
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = merge(out[k], v, here)
        elif here in CONCAT and isinstance(v, list) and isinstance(out.get(k), list):
            out[k] = out[k] + v
        else:
            out[k] = v
    return out


def _ext_path(p, e):
    """Where `extends: e` in file p points: relative to p, else to the kit (e.g. packs/sample/pair.sample.yaml)."""
    q = pathlib.Path(os.path.expanduser(str(e)))
    if not q.is_absolute():
        q = next((c for c in (p.parent / q, KIT_ROOT / q, p.parent / "builder-tester-agents" / q) if c.is_file()),
                 KIT_ROOT / q)
    return q


def _parse(p):
    text = p.read_text()
    if not text.strip():
        # an empty file is a broken pair.yaml, not "no settings": the guards must fail closed, not switch off
        raise SystemExit(f"{p} is empty")
    cfg = yaml.safe_load(text) if yaml else json.loads(text)
    if not isinstance(cfg, dict):
        raise SystemExit(f"{p} is not a mapping of settings")
    return cfg


def _read(p, seen):
    if p in seen:
        raise SystemExit(f"pair.yaml: `extends` loops back to {p}")
    seen = seen | {p}
    cfg = _parse(p)
    ext = cfg.pop("extends", None)
    base = {}
    for e in ([ext] if isinstance(ext, str) else list(ext or [])):
        q = _ext_path(p, e)
        if not q.is_file():
            raise SystemExit(f"pair.yaml: extends {e!r} not found (looked next to {p} and in {KIT_ROOT})")
        base = merge(base, _read(q.resolve(), seen))
    return merge(base, cfg)


def chain(path=None):
    """Real paths of the settings file and every file its `extends:` pulls in (best effort, never raises)."""
    out = []

    def walk(q):
        try:
            q = q.resolve()
        except OSError:
            return
        if str(q) in out:
            return
        out.append(str(q))
        try:
            ext = _parse(q).get("extends")
        except BaseException:
            return
        for e in ([ext] if isinstance(ext, str) else list(ext or [])):
            walk(_ext_path(q, e))
    p = pathlib.Path(path).expanduser() if path else find_config()
    if p:
        walk(p)
    return out


def load(path=None):
    """Load pair.yaml. `extends: <file or list>` loads those first (e.g. an organisation pack) and this file wins."""
    p = pathlib.Path(path).expanduser() if path else find_config()
    if not p or not p.is_file():
        raise SystemExit("pair.yaml not found: run ./install.sh (or set PAIR_CONFIG) first")
    cfg = _read(p.resolve(), frozenset())
    cfg["_path"] = str(p)
    return cfg


def get(cfg, dotted, default=None):
    cur = cfg
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return default
    return cur


def role(cfg=None, host=None):
    """Which role this machine plays, decided by hostname (never by an env var an agent could set)."""
    cfg = cfg or load()
    host = host or socket.gethostname()
    for r in ROLES:
        if get(cfg, f"{r}.host") == host:
            return r
    return "unknown"


def name(cfg, r):
    return get(cfg, f"{r}.name", r.capitalize())


def ledger_dir(cfg):
    return pathlib.Path(os.path.expanduser(get(cfg, "paths.ledger") or
                                           os.path.join(get(cfg, "paths.shared_root", "."), "pair-ledger")))


def apps(cfg):
    return {r["app"]: r for r in (get(cfg, "repos") or []) if isinstance(r, dict) and r.get("app")}


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "role":
        print(role())
    elif len(sys.argv) == 3 and sys.argv[1] == "get":
        v = get(load(), sys.argv[2])
        print(json.dumps(v, default=str) if isinstance(v, (dict, list)) else ("" if v is None else v))
    elif sys.argv[1:] == ["--selftest"]:
        import tempfile
        bad = 0
        with tempfile.TemporaryDirectory() as d:
            d = pathlib.Path(d)
            (d / "org.yaml").write_text("jira: {project: ORG, card_rules: {issue_type: Story}}\nrules: {standing: [{rule: org rule}], max_rounds: 3}\n")
            (d / "pair.yaml").write_text("extends: org.yaml\njira: {project: PAY}\nrules: {standing: [{rule: my rule}]}\n")
            c = load(d / "pair.yaml")
            for name, ok in [("child value wins", get(c, "jira.project") == "PAY"),
                             ("base value kept", get(c, "jira.card_rules.issue_type") == "Story" and get(c, "rules.max_rounds") == 3),
                             ("standing rules add up, base first", [r["rule"] for r in get(c, "rules.standing")] == ["org rule", "my rule"]),
                             ("extends key not left in the config", "extends" not in c)]:
                print(("PASS " if ok else "FAIL ") + name); bad += not ok
            (d / "org.yaml").write_text("extends: pair.yaml\n")
            try:
                load(d / "pair.yaml"); ok = False
            except SystemExit as e:
                ok = "loops" in str(e)
            print(("PASS " if ok else "FAIL ") + "extends loop refused"); bad += not ok
            (d / "pair.yaml").write_text("extends: packs/sample/pair.sample.yaml\n")
            if (KIT_ROOT / "packs/sample/pair.sample.yaml").is_file():
                ok = bool(get(load(d / "pair.yaml"), "rules.standing"))
                print(("PASS " if ok else "FAIL ") + "kit-relative pack path resolves"); bad += not ok
        print("ALL PASS" if not bad else f"{bad} FAILED")
        sys.exit(1 if bad else 0)
    elif len(sys.argv) == 2 and sys.argv[1] == "path":
        print(load()["_path"])
    else:
        sys.exit("usage: pairconf.py get <dotted.key> | role | path")
