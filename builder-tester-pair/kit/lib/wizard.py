#!/usr/bin/env python3
# Engram is the memory store named here. What it is and how to reach it is documented in exactly one place: [Engram](../../../starter-kit/instance/AUTHENTICATION.md#engram)
"""wizard — the setup questions (kit/lib/questions.yaml), asked ONE at a time, by the terminal or by Claude.

Both front ends share this engine, so they ask the same questions with the same defaults:
  terminal:  ./setup-pair ask                       fills what it can automatically, asks the rest one at a time
                                                    (Enter keeps the [default]), then shows the summary to confirm
  Claude:    ./setup-pair ask --auto                fills every answer that needs no person (measured, derived,
                                                    already in the file or its pack, safe defaults)
             ./setup-pair ask --auto --next [--json]  the next question nobody could decide (with its default and how
                                                    to look the value up); Claude looks it up or asks the person, then
             ./setup-pair set <key> <value>         records the answer (lists: comma separated; complex: JSON)
             ./setup-pair skip <section name>       the person does not use that section (e.g. Slack)
             ./setup-pair ask --summary [--json]    every answer, its value and where it came from, plus what is left
Every answer is written to pair.yaml immediately, so setup can stop and resume anywhere. Progress (which questions
were answered or skipped, and where each answer came from) is kept next to it in .pair-setup-state.json.
"""
import functools
import json
import os
import pathlib
import re
import socket
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import pairconf  # noqa: E402
import rules as pairrules  # noqa: E402

KIT = pathlib.Path(__file__).resolve().parents[2]
QFILE = KIT / "kit" / "lib" / "questions.yaml"


@functools.lru_cache(maxsize=1)
def _questions(mtime):
    return yaml.safe_load(QFILE.read_text())["sections"]


def questions():
    """Parsed once per process (re-read if the file changes); callers must not modify it."""
    return _questions(QFILE.stat().st_mtime)


# ---------------------------------------------------------------- file + state
def target(path=None):
    """The pair.yaml being written: --file, $PAIR_CONFIG, an existing pair.yaml found the usual way, else ./pair.yaml."""
    if path:
        return pathlib.Path(path).expanduser()
    if os.environ.get("PAIR_CONFIG"):
        return pathlib.Path(os.environ["PAIR_CONFIG"]).expanduser()
    return pairconf.find_config() or pathlib.Path.cwd() / "pair.yaml"


def load_raw(p):
    """This file only (not merged with `extends`), so writing it back never copies a pack into it."""
    return (yaml.safe_load(p.read_text()) or {}) if p.exists() else {}


def save_raw(p, cfg):
    p.parent.mkdir(parents=True, exist_ok=True)
    head = "# pair.yaml — written by the setup wizard (./setup or /pair-setup); edit freely. Docs: pair.example.yaml\n"
    p.write_text(head + yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True))


def state_file(p):
    return p.with_name(".pair-setup-state.json")


def load_state(p):
    f = state_file(p)
    st = json.loads(f.read_text()) if f.exists() else {}
    for k in ("answered", "skipped_sections", "used_sections"):
        st.setdefault(k, [])
    st.setdefault("auto", {})  # key -> where its answer came from: detected|derived|existing|pack|default|you
    return st


def save_state(p, st):
    state_file(p).write_text(json.dumps(st, indent=1))


def getd(d, key):
    cur = d
    for k in key.split("."):
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def setd(d, key, value):
    parts = key.split(".")
    for k in parts[:-1]:
        if not isinstance(d.get(k), dict):
            d[k] = {}
        d = d[k]
    d[parts[-1]] = value


# ---------------------------------------------------------------- defaults
def merged(p):
    """The config as the agents will see it (with `extends`), for defaults and `when:` conditions."""
    try:
        return pairconf.load(p) if p.exists() else {}
    except SystemExit:
        return load_raw(p)


def concat_key(key):
    """A list that ADDS to the pack's list on load (pairconf.CONCAT): its default must come from this file alone."""
    return tuple(key.split(".")) in pairconf.CONCAT


def resolve_default(q, cfg, own=None):
    """The value offered as the default. `cfg` is the merged config; `own` is this file alone (load_raw).
    For a CONCAT key (rules.standing) the current value is read from `own` only: offering the merged list would
    write the pack's entries into this file, and on load they would be added a second time."""
    d = q.get("default")
    if q["key"] == "extends":
        # `extends` is popped by the merged load, so the merged config never has it: read it from the RAW file
        if own is None:
            own = load_raw(pathlib.Path(cfg["_path"])) if isinstance(cfg, dict) and cfg.get("_path") else {}
        cur = own.get("extends")
        return cur if cur not in (None, "", []) else d
    cur = getd(own if (concat_key(q["key"]) and own is not None) else cfg, q["key"])
    if concat_key(q["key"]) and own is None:
        cur = None  # never offer a merged CONCAT list
    if cur not in (None, "", [], {}):
        return cur
    if not isinstance(d, str) or ":" not in d or not d.split(":", 1)[0] in ("detect", "derive"):
        return d
    kind, what = d.split(":", 1)
    return computed(kind, what, cfg)


@functools.lru_cache(maxsize=8)
def _identity(cwd):
    return pairrules.detect_identity(cwd=cwd)


def computed(kind, what, cfg):
    """The measured (detect:) or derived (derive:) value, ignoring whatever the file holds now."""
    root = getd(cfg, "paths.shared_root")
    if kind == "detect":
        if what == "hostname":
            return socket.gethostname()
        if what == "workspace":
            return os.environ.get("CODER_WORKSPACE_NAME", "")
        if what == "shared_root":
            here = KIT.parent
            return str(here) if here != pathlib.Path("/") else ""
        if what.startswith("identity."):
            return _identity(root if root and os.path.isdir(root) else None).get(what.split(".", 1)[1], "")
        return ""
    slug =getd(cfg, "project.slug") or re.sub(r"[^a-z0-9]+", "-", str(getd(cfg, "project.name") or "project").lower()).strip("-")
    b = str(getd(cfg, "builder.name") or "builder").lower()
    t = str(getd(cfg, "tester.name") or "tester").lower()
    owner = str(getd(cfg, "owner.name") or "").strip()
    r = str(root).rstrip("/") if root else ""
    return {"slug": slug, "builder_start": f"{b}-start", "tester_start": f"{t}-start", "builder_label": f"agent-{b}",
            "tester_label": f"agent-{t}", "owner_name": [owner] if owner else [],
            "short_name": owner.split()[0] if owner else "",
            "ledger": f"{r}/pair-ledger" if r else "", "knowledge_drafts": f"{r}/knowledge/drafts" if r else "",
            "knowledge_src": f"{r}/knowledge/src" if r else "",
            "slug-knowledge": f"{slug}-knowledge", "slug-builder-memory": f"{slug}-{b}-memory",
            "slug-builder-behaviors": f"{slug}-{b}-behaviors", "slug-tester-memory": f"{slug}-{t}-memory",
            "slug-tester-behaviors": f"{slug}-{t}-behaviors", "slug-builder-sessions": f"{slug}-{b}-sessions",
            "slug-tester-sessions": f"{slug}-{t}-sessions"}.get(what, "")


COMPLEX = ("repos", "rules", "channels", "environments", "areas", "lines", "suites")  # answered as JSON (or item by item)


def convert(q, raw):
    """Text answer → the value stored in pair.yaml, by question type."""
    t = q.get("type", "text")
    if isinstance(raw, str):
        s = raw.strip()
        if not s:  # blank: an empty value of the question's own type (never [] for a text/id question)
            if t in COMPLEX or t == "list":
                return []
            if t == "bool":
                return False
            if isinstance(q.get("default"), int) and not isinstance(q.get("default"), bool):
                return q["default"]  # a number left blank keeps its default rather than becoming ""
            return ""
        if t in COMPLEX or (s[0] in "[{" and t in ("list", "text")):
            try:
                return json.loads(s)
            except ValueError:
                if t in COMPLEX:
                    raise SystemExit(f"{q['key']}: give JSON, e.g. " + EXAMPLES.get(t, "[]"))
        if t == "list":
            return [x.strip() for x in s.split(",") if x.strip()]
        if t == "bool":
            return s.lower() in ("y", "yes", "true", "1", "on")
        if t == "choice" and q.get("choices") and s not in q["choices"]:
            raise SystemExit(f"{q['key']}: choose one of {q['choices']}")
        if re.fullmatch(r"\d+", s) and isinstance(q.get("default"), int):
            return int(s)
        return s
    return raw


EXAMPLES = {
    "repos": '[{"app": "api", "github": "org/api", "base": "main", "deployed": "", "aliases": ["payments api"], '
             '"services": ["api-gateway"], "infra": ["dev-1"], "sut_namespaces": ["payments-dev"]}]',
    "rules": '[{"rule": "Never merge — I merge.", "why": "approve is not merge", "for": "both"}]',
    "channels": '[{"key": "dev", "id": "C0123", "name": "#dev"}]',
    "environments": '[{"name": "dev", "cluster": "dev-1", "branches": ["release/*"], "team_requests": "allowed"}]',
    "areas": '[{"name": "payments", "apps": ["api"], "focus": "intake, limits, refunds"}, '
             '{"name": "cross", "apps": ["api", "web"], "focus": "auth, messaging, deployment"}]',
    "lines": '[{"app": "api", "name": "aws", "branch": "main"}]',
    "suites": '[{"app": "api", "owner": "Team X"}]',
}


# ---------------------------------------------------------------- walk
def pending(p):
    """(section, question) pairs still to ask, in order."""
    raw, st, cfg = load_raw(p), load_state(p), merged(p)
    out = []
    for sec in questions():
        if sec["name"] in st["skipped_sections"]:
            continue
        if sec.get("when") and not getd(cfg, sec["when"]):
            continue
        if sec.get("use") and sec["name"] not in st["used_sections"]:
            out.append((sec, {"key": f"@use:{sec['name']}", "ask": sec["use"], "type": "bool", "default": True}))
            continue
        for q in sec["questions"]:
            if q["key"] in st["answered"]:
                continue
            if q.get("when") and not getd(cfg, q["when"]):
                continue
            out.append((sec, q))
    return out


def pack_path(p, v):
    """An `extends` answer → the ABSOLUTE path of the pack file, looked up the way pairconf does (next to pair.yaml,
    then in the kit). A relative path breaks once the hooks are installed and run from another folder."""
    if not isinstance(v, str):
        return v  # a list of packs is stored as given
    q = pathlib.Path(os.path.expanduser(v.strip()))
    cands = [q] if q.is_absolute() else [p.parent / q, KIT / q, p.parent / "builder-tester-agents" / q]
    hit = next((c for c in cands if c.is_file()), None)
    if not hit:
        raise SystemExit(f"extends: {v!r} not found (looked next to {p} and in {KIT})")
    return str(hit.resolve())


def record(p, key, value, source="you"):
    """Write one answer. `source` says where it came from (shown by the summary): you (typed / `set`), or an automatic
    fill — detected | derived | existing | pack | default. `existing` and `pack` values are already in force, so they are
    only marked answered: writing a pack value into this file would pin it and hide later pack changes."""
    st, raw = load_state(p), load_raw(p)
    if key.startswith("@use:"):
        name = key[5:]
        yes = value if isinstance(value, bool) else str(value).lower() in ("y", "yes", "true", "1")
        for lst in (st["used_sections"], st["skipped_sections"]):
            if name in lst:
                lst.remove(name)
        (st["used_sections"] if yes else st["skipped_sections"]).append(name)
        st["auto"][key] = source
        save_state(p, st)
        return
    q = next((q for s in questions() for q in s["questions"] if q["key"] == key), {"key": key})
    if key == "extends":
        v = value.strip() if isinstance(value, str) else value
        if v in ("none", "", None):
            if "extends" in raw:
                raw.pop("extends")
                save_raw(p, raw)
        else:
            v = pack_path(p, v)
            if raw.get("extends") != v:
                raw["extends"] = v
                save_raw(p, raw)
    elif source not in ("existing", "pack"):
        setd(raw, key, convert(q, value))
        save_raw(p, raw)
    if key not in st["answered"]:
        st["answered"].append(key)
    st["auto"][key] = source
    save_state(p, st)


# ---------------------------------------------------------------- auto-fill
def filled(v):
    return v not in (None, "", [], {})


# derive:<what> → the answers it is computed from; it is only filled automatically once all of them have a value,
# so a slug is never derived from the placeholder project name.
DERIVE_DEPS = {
    "slug": ["project.name"], "builder_start": ["builder.name"], "tester_start": ["tester.name"],
    "builder_label": ["builder.name"], "tester_label": ["tester.name"], "owner_name": ["owner.name"],
    "short_name": ["owner.name"], "ledger": ["paths.shared_root"], "knowledge_drafts": ["paths.shared_root"],
    "knowledge_src": ["paths.shared_root"], "slug-knowledge": ["project.slug"],
    "slug-builder-memory": ["project.slug", "builder.name"], "slug-builder-behaviors": ["project.slug", "builder.name"],
    "slug-builder-sessions": ["project.slug", "builder.name"], "slug-tester-memory": ["project.slug", "tester.name"],
    "slug-tester-behaviors": ["project.slug", "tester.name"], "slug-tester-sessions": ["project.slug", "tester.name"],
}
SOURCE_LABEL = {"detected": "auto-detected", "derived": "derived", "existing": "existing", "pack": "pack",
                "default": "default", "you": "you"}


def section_of(name):
    return next(s for s in questions() if s["name"] == name)


def decide(q, raw, cfg):
    """(value, source) when the answer needs no person, else None."""
    key = q["key"]
    if key.startswith("@use:"):  # a section gate is a yes only when the section is already in use
        qs = section_of(key[5:])["questions"]
        if any(filled(getd(raw, x["key"])) for x in qs):
            return True, "existing"
        if any(filled(getd(cfg, x["key"])) for x in qs if not concat_key(x["key"])):
            return True, "pack"
        return None
    if key == "extends":
        return (raw["extends"], "existing") if filled(raw.get("extends")) else None
    if filled(getd(raw, key)):
        return getd(raw, key), "existing"
    if not concat_key(key) and filled(getd(cfg, key)):  # a CONCAT list (your own rules) is never "the pack's"
        return getd(cfg, key), "pack"
    d, t = q.get("default"), q.get("type", "text")
    if isinstance(d, str) and d.split(":", 1)[0] in ("detect", "derive") and ":" in d:
        kind, what = d.split(":", 1)
        if kind == "derive" and not all(filled(getd(cfg, k)) for k in DERIVE_DEPS.get(what, [])):
            return None
        v = computed(kind, what, cfg)
        return (v, "detected" if kind == "detect" else "derived") if filled(v) else None
    if q.get("auto") is False:
        return None
    if t == "bool" and isinstance(d, bool):
        return d, "default"
    if (t == "list" or q.get("auto")) and filled(d):
        return d, "default"
    return None


def auto_fill(p):
    """Record every pending answer that needs no person, until nothing more can be decided (an answer can open a
    section or complete a derive's inputs). Waits while `extends` is undecided: the pack changes the other defaults."""
    done = {}
    while True:
        todo = pending(p)
        raw = load_raw(p)
        if any(q["key"] == "extends" for _, q in todo) and not filled(raw.get("extends")):
            return {"filled": len(done), "pending": len(todo), "sources": done, "waiting_on": "extends"}
        cfg, progress = merged(p), False
        for _, q in todo:
            got = decide(q, raw, cfg)
            if got is None:
                continue
            record(p, q["key"], got[0], source=got[1])
            done[q["key"]] = got[1]
            progress = True
        if not progress:
            return {"filled": len(done), "pending": len(todo), "sources": done, "waiting_on": None}


def auto_text(r):
    by = {}
    for s in r["sources"].values():
        by[s] = by.get(s, 0) + 1
    detail = ", ".join(f"{SOURCE_LABEL[s]} {n}" for s, n in sorted(by.items()))
    out = f"Filled {r['filled']} automatically" + (f" ({detail})" if detail else "") + \
          f"; {r['pending']} still need an answer."
    if r["waiting_on"]:
        out += f"\n  Answer `{r['waiting_on']}` first (the pack changes the other defaults), then run --auto again."
    return out


def change(p, key, value):
    """The person changes an answer: record it as theirs, then re-derive the answers derived from it."""
    record(p, key, value, source="you")
    return rederive(p, key)


def rederive(p, key):
    changed, out = {key}, []
    qs = {q["key"]: q for s in questions() for q in s["questions"]}
    while True:
        st, cfg, again = load_state(p), merged(p), False
        for k, src in st["auto"].items():
            q = qs.get(k)
            if src != "derived" or not q or not str(q.get("default", "")).startswith("derive:"):
                continue
            what = q["default"].split(":", 1)[1]
            if not changed & set(DERIVE_DEPS.get(what, [])):
                continue
            v = computed("derive", what, cfg)
            if filled(v) and v != getd(cfg, k):
                record(p, k, v, source="derived")
                out.append((k, v))
                changed.add(k)
                again = True
                break
        if not again:
            return out


# ---------------------------------------------------------------- summary
def short(v, n=60):
    if isinstance(v, bool):
        s = "yes" if v else "no"
    elif isinstance(v, list) and all(not isinstance(x, (dict, list)) for x in v):
        s = ", ".join(map(str, v))
    elif isinstance(v, (list, dict)):
        s = (f"[{len(v)}] " if isinstance(v, list) else "") + json.dumps(v, ensure_ascii=False, separators=(",", ":"), default=str)
    else:
        s = str(v)
    return s if len(s) <= n else s[:n - 1] + "…"


def summary(p):
    """Every answer with its value and source, by section, plus what is still pending — for the person to confirm."""
    raw, cfg, st = load_raw(p), merged(p), load_state(p)
    pend = [q["key"] for _, q in pending(p)]
    secs = []
    for sec in questions():
        name, rows, status = sec["name"], [], "in use"
        gate = f"@use:{name}"
        if name in st["skipped_sections"]:
            status = "skipped"
        elif sec.get("when") and not getd(cfg, sec["when"]):
            status = f"not asked ({sec['when']} is not set)"
        elif sec.get("use") and name not in st["used_sections"]:
            status = "pending: " + sec["use"]
        else:
            if sec.get("use"):
                status = "in use (" + SOURCE_LABEL.get(st["auto"].get(gate, "you"), "you") + ")"
            for q in sec["questions"]:
                if q.get("when") and not getd(cfg, q["when"]):
                    continue
                k = q["key"]
                if k in pend:
                    rows.append({"key": k, "ask": q["ask"], "value": None, "source": "pending"})
                    continue
                v = (raw.get("extends") or "none") if k == "extends" else getd(cfg, k)
                rows.append({"key": k, "ask": q["ask"], "value": v, "source": st["auto"].get(k, "you")})
        secs.append({"section": name, "status": status, "answers": rows})
    counts = {}
    for s in secs:
        for r in s["answers"]:
            counts[r["source"]] = counts.get(r["source"], 0) + 1
    return {"file": str(p), "sections": secs, "pending": pend, "counts": counts}


def summary_text(s):
    lines = [f"Setup summary — {s['file']}",
             "  " + ", ".join(f"{SOURCE_LABEL.get(k, k)}: {n}" for k, n in sorted(s["counts"].items()))]
    for sec in s["sections"]:
        lines.append(f"\n== {sec['section']} ==" + ("" if sec["status"] == "in use" else f"  [{sec['status']}]"))
        for r in sec["answers"]:
            val = "(still to answer)" if r["source"] == "pending" else short(r["value"])
            lines.append(f"  {r['key']:<38} {val:<62} {SOURCE_LABEL.get(r['source'], r['source'])}")
    if s["pending"]:
        lines.append(f"\nStill to answer ({len(s['pending'])}): " + ", ".join(s["pending"]))
    else:
        lines.append("\nNothing left to answer.")
    return "\n".join(lines)


def show(sec, q, p):
    cfg = merged(p)
    d = resolve_default(q, cfg, load_raw(p)) if not q["key"].startswith("@use:") else q.get("default")
    hlp = q.get("help", "")
    if concat_key(q["key"]):
        inherited = len(getd(cfg, q["key"]) or []) - len(getd(load_raw(p), q["key"]) or [])
        if inherited > 0:
            hlp = (hlp + " " if hlp else "") + (f"The pack (extends) already adds {inherited}; they are kept automatically — "
                                                "list only your own here.")
    return {"section": sec["name"], "key": q["key"], "ask": q["ask"], "type": q.get("type", "text"),
            "choices": q.get("choices"), "default": d, "help": hlp, "lookup": q.get("lookup", ""),
            "example": EXAMPLES.get(q.get("type", "")), "left": len(pending(p))}


def ask_one(sec, q, p):
    """Ask ONE question in the terminal; returns the typed (or default) value, not yet recorded."""
    info = show(sec, q, p)
    if info["help"]:
        print(f"   ({info['help']})")
    t = info["type"]
    if t in COMPLEX:
        return ask_list(t, info)
    d = info["default"]
    dd = ("y" if d else "n") if t == "bool" else (", ".join(map(str, d)) if isinstance(d, list) else d)
    ch = f" {info['choices']}" if info.get("choices") else ""
    raw = input(f"{info['ask']}{ch}" + (f" [{dd}]" if dd not in (None, "") else "") + ": ").strip()
    value = raw if raw else (d if t != "bool" else bool(d))
    return "" if value is None else value


def terminal(p):
    """Fill what needs no person, ask the rest one at a time, then show the summary and let the person change any answer."""
    print(f"Setting up {p}. Answers that can be measured or derived are filled automatically and shown at the end to "
          "confirm.\nOne question at a time; Enter keeps the [default]; Ctrl-C to stop (answers so far are saved).\n")
    r = auto_fill(p)
    print(auto_text(r))
    last = None
    while True:
        r = auto_fill(p)
        if r["filled"]:
            print(f"   (filled {r['filled']} more automatically — shown in the summary at the end)")
        todo = pending(p)
        if not todo:
            break
        sec, q = todo[0]
        if sec["name"] != last:
            print(f"\n== {sec['name']} ==")
            last = sec["name"]
        try:
            record(p, q["key"], ask_one(sec, q, p))
        except SystemExit as e:
            print("  ", e)
    print("\n" + summary_text(summary(p)))
    qs = {q["key"]: (s, q) for s in questions() for q in s["questions"]}
    while True:
        k = input("\nChange anything? (key to change / Enter = all good): ").strip()
        if not k:
            break
        if k not in qs:
            print(f"   no question has the key {k!r} — copy it from the first column")
            continue
        try:
            for dk, dv in change(p, k, ask_one(*qs[k], p)):
                print(f"   re-derived {dk} = {short(dv)}")
            print(f"   {k} = {short(resolve_default(qs[k][1], merged(p), load_raw(p)))}  (you)")
        except SystemExit as e:
            print("  ", e)
    print(f"\nAll questions answered — {p}")
    return 0


LIST_FIELDS = {  # (field, prompt[, ask only when this earlier field was left blank])
    "repos": [("app", "app name (blank to finish)"), ("github", "GitHub owner/name (blank = give a remote URL instead)"),
              ("remote", "remote: any git URL or local path (optional)", "github"),
              ("base", "base branch PRs target"), ("deployed", "deployed branch (blank = base)"),
              ("aliases", "other words for it, comma separated"),
              ("services", "service names inside it, comma separated (blank = detect from the code)"),
              ("infra", "infrastructure names (clusters, namespaces), comma separated"),
              ("sut_namespaces", "namespaces the tester's runner must reach, comma separated"),
              ("health_url", "health URL (optional)")],
    "rules": [("rule", "rule, verbatim (blank to finish)"), ("why", "why (optional)"), ("for", "for: both | builder | tester")],
    "channels": [("id", "channel id (blank to finish)"), ("name", "channel name"), ("key", "short key")],
    "environments": [("name", "environment name (blank to finish)"), ("cluster", "cluster"),
                     ("branches", "branches, comma separated"), ("team_requests", "team requests: allowed | owner_only")],
    "areas": [("name", "area name, lowercase-dashes (blank to finish)"), ("apps", "apps it covers, comma separated"),
              ("focus", "focus: what the research agent reads for")],
    "lines": [("app", "app (blank to finish)"), ("name", "line name, e.g. aws"), ("branch", "branch it follows")],
    "suites": [("app", "app (blank to finish)"), ("owner", "who owns that suite")],
}
LIST_VALUED = {"aliases", "branches", "services", "infra", "sut_namespaces", "apps"}


def ask_list(t, info):
    """Repos / rules / channels / environments / areas / lines / suites: one item at a time, each field its own question."""
    fields = LIST_FIELDS[t]
    cur = info["default"] if isinstance(info["default"], list) else []
    if cur:
        keep = input(f"{info['ask']}: keep the {len(cur)} you have? [Y/n]: ").strip().lower()
        if keep in ("", "y", "yes"):
            return cur
        cur = []
    print(info["ask"])
    while True:
        item = {}
        for f in fields:
            k, label = f[0], f[1]
            if len(f) > 2 and item.get(f[2]):
                continue  # e.g. remote is only asked when github was left blank
            v = input(f"   {label}: ").strip()
            if k == fields[0][0] and not v:
                return cur
            if k in LIST_VALUED:
                v = [x.strip() for x in v.split(",") if x.strip()]
            if v not in ("", []):
                item[k] = v
        if t == "rules":
            item.setdefault("for", "both")
        cur.append(item)


def selftest():
    import tempfile
    bad = 0

    def expect(name, ok, detail=""):
        nonlocal bad
        print(("PASS " if ok else "FAIL ") + name, "" if ok else detail)
        bad += 0 if ok else 1
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d) / "pair.yaml"
        n0 = len(pending(p))
        expect("fresh file: every section asks", n0 > 20, n0)
        sec, q = pending(p)[0]
        expect("first question is the pack choice", q["key"] == "extends")
        record(p, "extends", "none")
        record(p, "project.name", "Pay Hub")
        info = show(*pending(p)[0], p)
        expect("derived default: slug from the name", info["key"] == "project.slug" and info["default"] == "pay-hub", info)
        record(p, "project.slug", "pay-hub")
        record(p, "builder.name", "Forge")
        sq = next(q for s in questions() for q in s["questions"] if q["key"] == "builder.start_command")
        expect("derived default: start command from the agent's name", resolve_default(sq, merged(p)) == "forge-start")
        record(p, "@use:Slack", "n")
        expect("a skipped section is never asked", not any(s["name"] == "Slack" for s, _ in pending(p)))
        record(p, "jira.card_rules.required_labels", "pay-phase1, D<n>")
        expect("list answer stored as a list", getd(load_raw(p), "jira.card_rules.required_labels") == ["pay-phase1", "D<n>"])
        record(p, "dark_factory.enabled", "y")
        expect("bool answer", getd(load_raw(p), "dark_factory.enabled") is True)
        expect("a `when:` question appears once its condition holds",
               any(q["key"] == "dark_factory.skills_dir" for _, q in pending(p)))
        record(p, "rules.standing", '[{"rule": "Never merge.", "for": "both"}]')
        expect("rules as JSON", getd(load_raw(p), "rules.standing")[0]["rule"] == "Never merge.")
        try:
            record(p, "repos", "not json"); ok = False
        except SystemExit as e:
            ok = "JSON" in str(e)
        expect("complex answer that is not JSON is refused with an example", ok)
        record(p, "extends", "packs/sample/pair.sample.yaml")
        pack_abs = str((KIT / "packs/sample/pair.sample.yaml").resolve())
        expect("pack chosen: stored as extends (absolute), the pack itself is not copied in",
               load_raw(p).get("extends") == pack_abs and getd(load_raw(p), "jira.project") is None, load_raw(p).get("extends"))
        st = load_state(p)
        expect("resume: answered keys are remembered", "project.name" in st["answered"] and "Slack" in st["skipped_sections"])
        di = resolve_default({"key": "identity.git_email", "default": "detect:identity.git_email"}, {})
        expect("identity default is measured, not typed", isinstance(di, str))

        # defect 1: a blank answer to a text/id question is "", never []
        record(p, "owner.teams_user_id", "")
        v = getd(load_raw(p), "owner.teams_user_id")
        expect("blank text answer stored as \"\" (not [])", v == "" and isinstance(v, str), repr(v))
        record(p, "owner.slack_not_self", "")
        expect("blank list answer stored as []", getd(load_raw(p), "owner.slack_not_self") == [])
        record(p, "knowledge.areas", "")
        expect("blank complex answer stored as []", getd(load_raw(p), "knowledge.areas") == [])
        record(p, "schedule.stall_minutes", "")
        expect("blank number keeps its default (not \"\")", getd(load_raw(p), "schedule.stall_minutes") == 45)

        # defect 2: rules.standing (pairconf.CONCAT) defaults from THIS file only, so accepting it never doubles a pack
        rq = next(q for s in questions() for q in s["questions"] if q["key"] == "rules.standing")
        pack_n = len(getd(pairconf.load(KIT / "packs/sample/pair.sample.yaml"), "rules.standing") or [])
        info = show({"name": "Your standing rules"}, rq, p)
        expect("rules.standing default = own rules only (not pack + own)",
               isinstance(info["default"], list) and len(info["default"]) == 1, len(info["default"] or []))
        expect("rules.standing help says the pack's rules are kept", f"adds {pack_n}" in info["help"], info["help"])
        record(p, "rules.standing", json.dumps(info["default"]))
        n = len(getd(pairconf.load(p), "rules.standing"))
        expect("accepting the rules.standing default does not double the pack", n == pack_n + 1, f"{n} != {pack_n}+1")
        expect("resolve_default never offers a merged CONCAT list without `own`",
               resolve_default(rq, pairconf.load(p)) in (None, []), resolve_default(rq, pairconf.load(p)))

        # defect 3: the settings a full pair.yaml and pair.example.yaml use are all asked
        keys = {q["key"] for s in questions() for q in s["questions"]}
        need = ["owner.short_name", "owner.teams_self_chat", "owner.slack_not_self", "slack.retired_channels",
                "jira.ignore_labels", "jira.card_rules.label_families", "jira.card_rules.priority", "jira.audience",
                "registry.push_host", "registry.pull_host", "registry.project", "schedule.fresh_start_utc",
                "schedule.stall_minutes", "paths.heartbeat", "paths.ledger", "paths.knowledge_drafts",
                "paths.knowledge_src", "knowledge.areas", "knowledge.lines", "argus.existing_suites", "argus.execution_hub",
                "listener.extra_keywords", "dark_factory.loop_skill", "engram.sessions_builder", "engram.sessions_tester",
                "team.decision_contact.teams_user_id", "rules.result_parsers", "rules.shared_writes", "scope.exclude",
                "project.topics", "tester.private_dir", "guard.credential_dirs", "guard.deploy_verbs"]
        missing = [k for k in need if k not in keys]
        expect("every example setting has a question", not missing, missing)
        qs = {q["key"]: q for s in questions() for q in s["questions"]}
        dcfg = {"project": {"slug": "pay"}, "builder": {"name": "Forge"}, "tester": {"name": "Gauge"},
                "owner": {"name": "Jane Q Doe"}, "paths": {"shared_root": "/fleet/pay/"}}
        got = {k: resolve_default(qs[k], dcfg) for k in ("owner.short_name", "owner.teams_self_chat", "paths.ledger",
                                                        "paths.knowledge_drafts", "paths.knowledge_src",
                                                        "engram.sessions_builder", "engram.sessions_tester",
                                                        "schedule.fresh_start_utc", "schedule.stall_minutes",
                                                        "dark_factory.loop_skill")}
        want = {"owner.short_name": "Jane", "owner.teams_self_chat": "48:notes", "paths.ledger": "/fleet/pay/pair-ledger",
                "paths.knowledge_drafts": "/fleet/pay/knowledge/drafts", "paths.knowledge_src": "/fleet/pay/knowledge/src",
                "engram.sessions_builder": "pay-forge-sessions", "engram.sessions_tester": "pay-gauge-sessions",
                "schedule.fresh_start_utc": ["02", "14"], "schedule.stall_minutes": 45,
                "dark_factory.loop_skill": "dark-factory-build"}
        expect("new derived / plain defaults", got == want, {k: got[k] for k in got if got[k] != want[k]})
        expect("new JSON kinds have examples that parse",
               all(isinstance(json.loads(EXAMPLES[t]), list) for t in ("areas", "lines", "suites")))
        record(p, "knowledge.lines", EXAMPLES["lines"])
        expect("lines answer stored as JSON", getd(load_raw(p), "knowledge.lines")[0]["name"] == "aws")
        try:
            record(p, "argus.existing_suites", "Team X"); ok = False
        except SystemExit as e:
            ok = "JSON" in str(e)
        expect("suites answer that is not JSON is refused with an example", ok)
        expect("team.decision_contact.teams_user_id only asked once a contact is named",
               qs["team.decision_contact.teams_user_id"].get("when") == "team.decision_contact.name")
        bad_default = [k for k, q in qs.items() if q.get("type") in ("list",) + COMPLEX
                       and not isinstance(q.get("default", []), list) and not str(q.get("default", "")).startswith("derive:")]
        expect("every list/JSON question defaults to a list", not bad_default, bad_default)

        # defect 4: the terminal repos item asks services / infra / sut_namespaces / remote / health_url
        import builtins
        answers = iter(["web", "", "https://git.example.com/web.git", "main", "", "front end", "", "dev-1, dev-2",
                        "web-dev", "https://web.example.com/healthz",
                        "api", "org/api", "main", "", "", "api-gw, api-worker", "", "", "", ""])
        real_input = builtins.input
        builtins.input = lambda prompt="": next(answers)
        try:
            items = ask_list("repos", {"ask": "Repos", "default": []})
        finally:
            builtins.input = real_input
        web, api = items
        expect("terminal repos: remote asked when github is blank, lists stored as lists",
               web == {"app": "web", "remote": "https://git.example.com/web.git", "base": "main", "aliases": ["front end"],
                       "infra": ["dev-1", "dev-2"], "sut_namespaces": ["web-dev"],
                       "health_url": "https://web.example.com/healthz"}, web)
        expect("terminal repos: remote skipped when github given; blank services = detect (omitted)",
               api == {"app": "api", "github": "org/api", "base": "main", "services": ["api-gw", "api-worker"]}, api)
        expect("terminal asks the new JSON kinds item by item", all(t in LIST_FIELDS for t in ("areas", "lines", "suites")))

        # auto-fill: everything that needs no person is filled, with its source; id lookups stay pending
        a = pathlib.Path(d) / "auto" / "pair.yaml"
        r0 = auto_fill(a)
        expect("auto-fill waits for `extends` on a fresh file (the pack changes the defaults)",
               r0["filled"] == 0 and r0["waiting_on"] == "extends", r0)
        a.parent.mkdir(parents=True, exist_ok=True)
        a.write_text("extends: packs/sample/pair.sample.yaml\nproject: {name: Pay Hub}\ntester: {workspace: pay-tester}\n")
        exq = next(q for s in questions() for q in s["questions"] if q["key"] == "extends")
        expect("extends default is read from the raw file (not 'none')",
               show({"name": "Start"}, exq, a)["default"] == "packs/sample/pair.sample.yaml", show({"name": "Start"}, exq, a)["default"])
        expect("extends default also right from a merged config alone",
               resolve_default(exq, merged(a)) == "packs/sample/pair.sample.yaml")
        r = auto_fill(a)
        st, raw = load_state(a), load_raw(a)
        src = st["auto"]
        expect("auto: existing relative extends rewritten to the absolute pack path",
               raw.get("extends") == pack_abs and src.get("extends") == "existing", raw.get("extends"))
        expect("auto: hostname detected", src.get("builder.host") == "detected"
               and raw["builder"]["host"] == socket.gethostname(), src.get("builder.host"))
        expect("auto: slug derived from the existing name", src.get("project.slug") == "derived"
               and getd(raw, "project.slug") == "pay-hub", getd(raw, "project.slug"))
        expect("auto: derived engram space follows the derived slug",
               getd(raw, "engram.knowledge") == "pay-hub-knowledge" and src.get("engram.knowledge") == "derived")
        expect("auto: value already in the file = existing", src.get("tester.workspace") == "existing")
        expect("auto: project.name already in the file = existing", src.get("project.name") == "existing")
        expect("auto: section the pack uses is opened (pack), its values are not copied into the file",
               src.get("@use:Jira") == "pack" and src.get("jira.project") == "pack" and getd(raw, "jira.project") is None,
               (src.get("@use:Jira"), src.get("jira.project"), getd(raw, "jira")))
        expect("auto: safe plain default with `auto: true` filled", src.get("rules.reviewer") == "default")
        expect("auto: bool default filled", src.get("dark_factory.enabled") == "default")
        left = {q["key"] for _, q in pending(a)}
        expect("auto: id lookups stay pending (Jira workspace id, Slack user id, k8s namespace)",
               {"jira.hub_workspace_id", "owner.slack_user_id", "tester.k8s_namespace"} <= left, sorted(left))
        expect("auto: tester host (no value) and Teams gate (not in use) stay pending",
               "tester.host" in left and "@use:Microsoft Teams" in left, sorted(left)[:8])
        expect("auto: a derive waits for its input (builder.name not answered)",
               "builder.start_command" in left and "builder.start_command" not in src)
        expect("auto: rules.standing (your own rules) is not filled from the pack", "rules.standing" in left)
        expect("auto: count printed", r["filled"] == len(src) and f"Filled {r['filled']} automatically" in auto_text(r))
        expect("auto: a second run fills nothing new", auto_fill(a)["filled"] == 0)

        sm = summary(a)
        rows = {x["key"]: x for s in sm["sections"] for x in s["answers"]}
        expect("summary: sources per answer",
               rows["builder.host"]["source"] == "detected" and rows["project.slug"]["source"] == "derived"
               and rows["tester.workspace"]["source"] == "existing" and rows["jira.project"]["source"] == "pack",
               {k: rows[k]["source"] for k in ("builder.host", "project.slug", "tester.workspace", "jira.project") if k in rows})
        expect("summary: pending questions listed", "tester.host" in sm["pending"] and rows["tester.host"]["source"] == "pending")
        txt = summary_text(sm)
        expect("summary text shows auto-detected / pack / still to answer",
               "auto-detected" in txt and " pack" in txt and "(still to answer)" in txt and "Still to answer" in txt)
        expect("summary: lists joined, long JSON shortened",
               short(["a", "b"]) == "a, b" and len(short([{"x": "y" * 200}])) <= 60)
        import datetime
        expect("summary: a YAML date inside a pack rule does not crash it",
               "2026-01-02" in short([{"since": datetime.date(2026, 1, 2)}]))

        record(a, "builder.name", "Forge")
        expect("set marks the source 'you'", load_state(a)["auto"].get("builder.name") == "you")
        auto_fill(a)
        expect("after the input is answered the derive fills", getd(load_raw(a), "builder.start_command") == "forge-start")
        redo = dict(change(a, "project.slug", "ph"))
        expect("changing an answer re-derives what came from it",
               getd(load_raw(a), "engram.knowledge") == "ph-knowledge" and redo.get("engram.builder_memory") == "ph-forge-memory"
               and load_state(a)["auto"]["project.slug"] == "you", redo)
        rows = {x["key"]: x for s in summary(a)["sections"] for x in s["answers"]}
        expect("summary shows 'you' after set", rows["project.slug"]["source"] == "you")
        try:
            record(a, "extends", "packs/nope/pair.nope.yaml"); ok = False
        except SystemExit as e:
            ok = "not found" in str(e)
        expect("extends that does not exist is refused", ok)
    print("ALL PASS" if not bad else f"{bad} FAILED")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:] == ["--selftest"] else "usage: ./setup-pair ask | ask --next | set | skip")
