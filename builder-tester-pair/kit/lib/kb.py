"""kb — the knowledge base's settings, read from the `knowledge:` section of pair.yaml, with safe defaults.

Every knowledge tool (knowledge-refresh, ./setup-pair knowledge, the /knowledge-build skill) gets its areas, page
kinds, graph relations, followed branches, ignore rules, growth triggers and log settings from `settings(cfg)`.
Nothing about a project is hard-coded here; an empty `knowledge:` section gives a working default library.

CLI:  python3 kb.py plan        the research plan (areas -> apps -> source folders -> page kinds), JSON
      python3 kb.py --selftest
"""
import copy
import fnmatch
import json
import os
import pathlib
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import pairconf  # noqa: E402

DEFAULT_KINDS = [
    {"name": "service", "about": "one deployable service: inputs/outputs, how it works, every rule it enforces"},
    {"name": "flow", "about": "one business action end to end across services, each hop cited"},
    {"name": "rules", "about": "a table of conditions: where enforced, outcome, error"},
    {"name": "links", "about": "who calls whom over which route / queue / table"},
    {"name": "concept", "about": "a domain idea several services share, every place it is defined or enforced"},
    {"name": "bug", "about": "one fixed bug: symptom, root cause, fix, guarding test, recurrence sign"},
    {"name": "deploy", "about": "how one app is built and deployed, per environment: image build + registry, manifests / "
                                "overlays, cluster + namespaces, the exact deploy and rollback commands, how to verify it "
                                "landed, who approves — cited to the deploy files, CI and the deploy rulebook"},
]
DEFAULT_RELATIONS = [
    {"name": "REQUIRES", "from": "requirement", "to": "page", "about": "a requirement needs the behaviour on this page"},
    {"name": "ENFORCES", "from": "service", "to": "rules", "about": "a service enforces the rules on that page"},
    {"name": "USES", "from": "flow", "to": "service", "about": "a flow passes through a service"},
    {"name": "CALLS", "from": "service", "to": "service", "about": "a service calls another (route, queue, table)"},
    {"name": "FIXES", "from": "bug", "to": "page", "about": "a bug page fixes behaviour described on a page or ticket"},
    {"name": "PUBLISHES_TO", "from": "service", "to": "links", "about": "a service publishes to a queue / topic / route"},
    {"name": "CONSUMES_FROM", "from": "service", "to": "links", "about": "a service consumes from a queue / topic / route"},
    {"name": "EXPLAINS", "from": "concept", "to": "page", "about": "a concept page explains an idea used on that page"},
    {"name": "PART_OF", "from": "page", "to": "page", "about": "a page is a part of a bigger page (sub-flow, sub-service)"},
    {"name": "SEE_ALSO", "from": "page", "to": "page", "about": "a related page worth reading next"},
    {"name": "DEPLOYS", "from": "deploy", "to": "service", "about": "a deploy page covers how that service is deployed"},
]
DEFAULT_ENGRAM_TITLE = "{AREA} · {kind} · {title}"
DEFAULT_GROW_ON = {"merge": True, "new_behaviour": True, "bug_fix": True, "test_flag": True, "requirement": True}
DEFAULT_IGNORE = ["vendor/", "node_modules/", "*.lock", "*.sum"]
DEFAULT_NEVER_READ = ["**/kits/**", "**/scenarios/**"]
COMMON_FILES = ["kustomization.yaml", "go.mod", "go.sum", "README.md", "CLAUDE.md", "Dockerfile", "main.go",
                "package.json", "package-lock.json", "values.yaml", "deployment.yaml", "service.yaml", "Program.cs",
                "appsettings.json", "index.ts", "pom.xml", "build.gradle", "requirements.txt", "pyproject.toml",
                "__init__.py", "Cargo.toml"]
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def _kinds(raw):
    out = []
    for k in raw or DEFAULT_KINDS:
        if isinstance(k, str):
            k = next((d for d in DEFAULT_KINDS if d["name"] == k), {"name": k, "about": ""})
        out.append({"name": str(k.get("name", "")), "about": str(k.get("about", ""))})
    return out


def _relations(raw):
    out = []
    for r in raw or DEFAULT_RELATIONS:
        if isinstance(r, str):
            r = next((d for d in DEFAULT_RELATIONS if d["name"] == r), {"name": r})
        out.append({"name": str(r.get("name", "")).upper(), "from": str(r.get("from", "")), "to": str(r.get("to", "")),
                    "about": str(r.get("about", ""))})
    return out


def branch_for(cfg, app, repo):
    """The branch the library follows for one app. Precedence: repos[].knowledge_branch, knowledge.branch.<app>,
    knowledge.branch (string), then the keyword's meaning: 'deployed' = repos[].deployed or base; 'base' = base."""
    kb = pairconf.get(cfg, "knowledge") or {}
    b = repo.get("knowledge_branch")
    br = kb.get("branch")
    if not b and isinstance(br, dict):
        b = br.get(app) or br.get("default")
    if not b and isinstance(br, str):
        b = br
    b = str(b or "deployed")
    if b == "deployed":
        return str(repo.get("deployed") or repo.get("base") or "main")
    if b == "base":
        return str(repo.get("base") or "main")
    return b


def settings(cfg):
    """Normalised knowledge settings. Raises ValueError listing every problem (never half-applies a bad config)."""
    kb = pairconf.get(cfg, "knowledge") or {}
    root = pairconf.get(cfg, "paths.shared_root") or "."
    drafts = pathlib.Path(os.path.expanduser(pairconf.get(cfg, "paths.knowledge_drafts") or f"{root}/knowledge/drafts"))
    src = pathlib.Path(os.path.expanduser(pairconf.get(cfg, "paths.knowledge_src") or f"{root}/knowledge/src"))
    apps = pairconf.apps(cfg)
    errs = []

    areas = []
    for a in kb.get("areas") or []:
        if isinstance(a, str):
            a = {"name": a, "apps": [a] if a in apps else []}
        areas.append({"name": str(a.get("name", "")), "apps": list(a.get("apps") or []), "focus": str(a.get("focus", "")),
                      "services": list(a.get("services") or [])})
    if not areas:  # default: one area per app, plus `cross` when there is more than one app
        areas = [{"name": app, "apps": [app], "focus": ""} for app in apps]
        if len(apps) > 1:
            areas.append({"name": "cross", "apps": list(apps),
                          "focus": "things that span apps: messaging, auth, deployment, observability"})
    seen = set()
    for a in areas:
        if not SLUG.match(a["name"]):
            errs.append(f"knowledge.areas: name {a['name']!r} must be lowercase letters, digits and dashes")
        if a["name"] in seen:
            errs.append(f"knowledge.areas: {a['name']!r} listed twice")
        seen.add(a["name"])
        for app in a["apps"]:
            if app not in apps:
                errs.append(f"knowledge.areas[{a['name']}]: app {app!r} is not in repos[] ({', '.join(apps) or 'none'})")
        if not a["apps"]:
            errs.append(f"knowledge.areas[{a['name']}]: list at least one app")

    kinds = _kinds(kb.get("kinds"))
    for k in kinds:
        if not SLUG.match(k["name"]):
            errs.append(f"knowledge.kinds: {k['name']!r} must be lowercase letters, digits and dashes")
    relations = _relations(kb.get("relations"))
    for r in relations:
        if not re.match(r"^[A-Z][A-Z_]*$", r["name"]):
            errs.append(f"knowledge.relations: {r['name']!r} must be UPPER_CASE")

    follow = {}
    for app, r in apps.items():
        follow[app] = {"app": app, "line": "", "branch": branch_for(cfg, app, r), "repo": r, "dir": str(src / app)}
    for ln in kb.get("lines") or []:  # another deployed line of the same app (e.g. per cloud / per customer)
        app, name, br = ln.get("app"), str(ln.get("name", "")), ln.get("branch")
        if app not in apps:
            errs.append(f"knowledge.lines: app {app!r} is not in repos[]")
            continue
        if not SLUG.match(name) or not br:
            errs.append(f"knowledge.lines[{app}]: needs name (lowercase) and branch")
            continue
        key = f"{app}-{name}"
        follow[key] = {"app": app, "line": name, "branch": str(br), "repo": apps[app], "dir": str(src / key)}

    grow = dict(DEFAULT_GROW_ON)
    for k, v in (kb.get("grow_on") or {}).items():
        if k not in DEFAULT_GROW_ON:
            errs.append(f"knowledge.grow_on: unknown trigger {k!r} (known: {', '.join(DEFAULT_GROW_ON)})")
        else:
            grow[k] = bool(v)

    never = list(DEFAULT_NEVER_READ) + list(kb.get("never_read") or [])
    kits = pairconf.get(cfg, "tester.kits_dir")
    if kits:
        never.append(str(kits).rstrip("/") + "/**")
    for r in pairconf.get(cfg, "argus.repos") or []:
        never.append(f"**/{str(r).split('/')[-1]}/**")

    try:
        sample = int(kb.get("adversary_sample", 5))
    except (TypeError, ValueError):
        sample, _ = 5, errs.append("knowledge.adversary_sample must be a number")
    title_fmt = str(kb.get("engram_title") or DEFAULT_ENGRAM_TITLE)
    if "{title}" not in title_fmt:
        errs.append("knowledge.engram_title must contain {title} (fields: {AREA} {area} {kind} {title})")
    if errs:
        raise ValueError("\n".join(errs))
    return {
        "enabled": bool(pairconf.get(cfg, "engram.knowledge")) or bool(kb),
        "engram": pairconf.get(cfg, "engram.knowledge") or "",
        "drafts": drafts, "src": src, "lib": drafts.parent,
        "areas": areas, "kinds": kinds, "relations": relations, "follow": follow,
        "ignore": list(kb.get("ignore") or DEFAULT_IGNORE),
        "common_files": set(COMMON_FILES) | set(kb.get("common_files") or []),
        "never_read": list(dict.fromkeys(never)),
        "grow_on": grow, "adversary_sample": sample,
        "git_history": bool(kb.get("git_history", True)),
        "log": pairconf.ledger_dir(cfg) / "knowledge-log.jsonl",
        "engram_title": title_fmt,
        "services_per_agent": max(1, int(kb.get("services_per_agent", 6) or 6)) if str(kb.get("services_per_agent", 6)).isdigit() else 6,
        "ids": drafts.parent / "graph" / "ids.json",
    }


def engram_title(s, area, kind, title):
    """The title a page gets in Engram, from knowledge.engram_title (default "AREA · kind · title")."""
    return s["engram_title"].format(AREA=area.upper(), area=area, kind=kind, title=title)


def ignored(path, patterns):
    """True when a changed file is outside the library's interest (third-party code, lock files…)."""
    p = path.lstrip("./")
    for pat in patterns:
        if pat.endswith("/"):
            if p.startswith(pat) or f"/{pat}" in f"/{p}":
                return True
        elif fnmatch.fnmatch(p, pat) or fnmatch.fnmatch(p.rsplit("/", 1)[-1], pat):
            return True
    return False


SERVICE_MARKERS = ("Dockerfile", "go.mod", "package.json", "pom.xml", "build.gradle", "pyproject.toml", "Cargo.toml",
                   "requirements.txt")
SKIP_DIRS = {"vendor", "node_modules", ".git", "test", "tests", "testdata", "docs", "examples", "dist", "build", "bin",
             "obj", ".github", "scripts", "third_party", "fixtures", "mocks", "e2e", "__pycache__", "tools",
             "deployments", "deploy", "k8s", "helm", "charts", "manifests", "infra", "terraform", "overlays"}


def detect_services(src, depth=3):
    """Deployable units inside one repo: folders (up to `depth` deep) holding a build or deploy marker — a Dockerfile,
    go.mod, package.json, *.csproj, pyproject.toml, Chart.yaml, … Nested markers under a found service count once.
    A repo with no marker below its root is one service ('.'). Returns sorted relative paths."""
    root = pathlib.Path(src)
    if not root.is_dir():
        return []
    found = []

    def has_marker(d):
        try:
            names = {x.name for x in d.iterdir() if x.is_file()}
        except OSError:
            return False
        return bool(names & set(SERVICE_MARKERS)) or any(n.endswith(".csproj") for n in names)

    def walk(d, lvl):
        try:
            kids = sorted(x for x in d.iterdir() if x.is_dir() and x.name not in SKIP_DIRS and not x.name.startswith("."))
        except OSError:
            return
        for k in kids:
            if has_marker(k):
                cmds = sorted(c for c in (k / "cmd").iterdir() if c.is_dir()) if (k / "cmd").is_dir() else []
                if len(cmds) > 1:  # one module building several programs (Go cmd/<name>): each is a service
                    found.extend(str(c.relative_to(root)) for c in cmds)
                else:
                    found.append(str(k.relative_to(root)))
            elif lvl < depth:
                walk(k, lvl + 1)
    walk(root, 1)
    if has_marker(root):  # the repo root builds a service itself (single-service repo, or a root app beside others)
        cmds = sorted(c for c in (root / "cmd").iterdir() if c.is_dir()) if (root / "cmd").is_dir() else []
        if len(cmds) > 1:  # a root module building several programs (Go cmd/<name>): each is a service
            found.extend(str(c.relative_to(root)) for c in cmds)
        else:
            found.append(".")
    return sorted(found) or (["."] if any(root.iterdir()) else [])


DEPLOY_DIRS = ("deployments", "deploy", "k8s", "kubernetes", "helm", "charts", "manifests", "overlays", ".github/workflows",
               ".azure-pipelines", "pipelines", "terraform", "infra")
DEPLOY_FILES = ("Dockerfile", "Makefile", "Taskfile.yml", "skaffold.yaml", "azure-pipelines.yml", ".gitlab-ci.yml",
                "Jenkinsfile", "docker-compose.yml", "docker-compose.yaml")


def detect_deploy_files(src, limit=40):
    """Where an app's deployment is defined: deploy folders (manifests, overlays, charts, CI workflows, IaC) and build /
    deploy files at the root or one level down, plus *deploy*/*rollout* scripts. Relative paths, sorted, capped."""
    root = pathlib.Path(src)
    if not root.is_dir():
        return []
    out = set()
    for d in DEPLOY_DIRS:
        if (root / d).is_dir():
            out.add(d + "/")
    for p in [root] + [x for x in root.iterdir() if x.is_dir() and x.name not in SKIP_DIRS and not x.name.startswith(".")]:
        for n in DEPLOY_FILES:
            if (p / n).is_file():
                out.add(str((p / n).relative_to(root)))
    for p in root.rglob("*"):
        if p.is_file() and p.suffix in (".sh", ".ps1", ".mk") and any(w in p.name.lower() for w in ("deploy", "rollout", "rollback", "release")) \
                and not set(p.relative_to(root).parts) & {"vendor", "node_modules", ".git"}:
            out.add(str(p.relative_to(root)))
        if len(out) >= limit:
            break
    return sorted(out)[:limit]


def deploy_home(s, app):
    """The area that holds an app's deploy page(s): the first area covering only that app, else the first area that
    lists it (a shared `cross` area last)."""
    alone = [a["name"] for a in s["areas"] if a["apps"] == [app]]
    some = [a["name"] for a in s["areas"] if app in a["apps"] and a["name"] != "cross"]
    return (alone or some or [a["name"] for a in s["areas"] if app in a["apps"]] or [""])[0]


def services(s, app):
    """Services of an app: repos[].services when the person listed them, else those detected at knowledge init."""
    listed = list(s["follow"].get(app, {}).get("repo", {}).get("services") or [])
    if listed:
        return listed
    f = s["lib"] / "graph" / "services.json"
    try:
        got = json.loads(f.read_text()).get(app)
        if got is not None:
            return list(got)
    except (OSError, ValueError):
        pass
    d = s["follow"].get(app, {}).get("dir")
    return detect_services(d) if d else []


def area_services(s, area):
    """The services an area researches: the area's own `services:` list when it has one (names or path globs, matched
    against each app's services), else every service of its apps that no other area of the same app claims."""
    out = []
    for app in area["apps"]:
        svcs = services(s, app)
        if area.get("services"):
            out += [f"{app}:{x}" for x in svcs if any(fnmatch.fnmatch(x, g) or pathlib.PurePath(x).name == g
                                                     for g in area["services"])]
            continue
        claimed = {x for b in s["areas"] if b is not area and app in b["apps"] and b.get("services")
                   for x in svcs if any(fnmatch.fnmatch(x, g) or pathlib.PurePath(x).name == g for g in b["services"])}
        out += [f"{app}:{x}" for x in svcs if x not in claimed]
    return out


def plan(cfg):
    """What a fresh build researches: one item per area, with the source folders and page kinds to use."""
    s = settings(cfg)
    items = []
    for a in s["areas"]:
        srcs = [{"key": k, "app": f["app"], "line": f["line"], "branch": f["branch"], "dir": f["dir"]}
                for k, f in s["follow"].items() if f["app"] in a["apps"]]
        svcs = area_services(s, a)
        size = s["services_per_agent"]
        batches = [svcs[i:i + size] for i in range(0, len(svcs), size)] or [[]]
        deploys = [{"app": f["app"], "line": f["line"], "branch": f["branch"], "files": detect_deploy_files(f["dir"])}
                   for k, f in s["follow"].items() if f["app"] in a["apps"] and deploy_home(s, f["app"]) == a["name"]]
        items.append({"area": a["name"], "focus": a["focus"], "sources": srcs, "services": svcs, "deploy_pages": deploys,
                      "research_batches": batches,
                      "drafts": str(s["drafts"] / a["name"]), "kinds": [k["name"] for k in s["kinds"]]})
    return {"engram": s["engram"], "library": str(s["lib"]), "brief": str(s["lib"] / "BRIEF.md"),
            "page_template": str(s["lib"] / "page-template.md"), "adversary_sample": s["adversary_sample"],
            "relations": [r["name"] for r in s["relations"]], "never_read": s["never_read"], "areas": items}


def render_brief(template, cfg, pins):
    """Fill the brief's tables from pair.yaml and the pinned commits."""
    s = settings(cfg)
    rows = "\n".join(f"| {k} | {f['dir']} | {f['branch']} @ {(pins.get(k) or '')[:12] or 'not pinned yet'} |"
                     for k, f in s["follow"].items()) or "| (no repos in pair.yaml) | | |"
    areas = "\n".join(f"| {a['name']} | {', '.join(a['apps'])} | {a['focus'] or '-'} |" for a in s["areas"])
    kinds = "\n".join(f"| `{k['name']}` | {k['about'] or '-'} |" for k in s["kinds"])
    rels = "\n".join(f"| `{r['name']}` | {r['from'] or '-'} → {r['to'] or '-'} | {r['about'] or '-'} |" for r in s["relations"])
    lines = [k for k, f in s["follow"].items() if f["line"]]
    vals = {"sources_table": rows, "areas_table": areas, "kinds_table": kinds, "relations_table": rels,
            "never_read": ", ".join(f"`{p}`" for p in s["never_read"]), "drafts": str(s["drafts"]),
            "engram": s["engram"] or "(engram.knowledge not set: pages stay as drafts)",
            "lines_note": ("Lines tracked besides the main one: " + ", ".join(f"`{k}`" for k in lines)) if lines
            else "Only one line per app is tracked.",
            "adversary_sample": str(s["adversary_sample"])}
    return re.sub(r"\{\{(\w+)\}\}", lambda m: vals.get(m.group(1), m.group(0)), template)


def selftest():
    bad = 0

    def expect(name, ok, detail=""):
        nonlocal bad
        bad += not ok
        print("PASS" if ok else "FAIL", name, "" if ok else str(detail)[-300:])

    base = {"paths": {"shared_root": "/x"}, "repos": [{"app": "api", "github": "o/api", "base": "main", "deployed": "release"},
                                                      {"app": "web", "github": "o/web", "base": "develop"}]}
    s = settings(base)
    expect("default areas = one per app + cross", [a["name"] for a in s["areas"]] == ["api", "web", "cross"], s["areas"])
    expect("default follows deployed, else base", s["follow"]["api"]["branch"] == "release" and s["follow"]["web"]["branch"] == "develop")
    expect("default kinds and relations", len(s["kinds"]) == 7 and "REQUIRES" in [r["name"] for r in s["relations"]])
    c = json.loads(json.dumps(base)); c["knowledge"] = {"branch": "main"}
    expect("knowledge.branch: main applies to every app", {f["branch"] for f in settings(c)["follow"].values()} == {"main"})
    c["knowledge"] = {"branch": {"default": "base", "api": "hotfix"}}
    s = settings(c)
    expect("per-app branch + default", s["follow"]["api"]["branch"] == "hotfix" and s["follow"]["web"]["branch"] == "develop")
    c["repos"][1]["knowledge_branch"] = "main"
    expect("repos[].knowledge_branch wins", settings(c)["follow"]["web"]["branch"] == "main")
    c = json.loads(json.dumps(base)); c["knowledge"] = {"lines": [{"app": "api", "name": "aws", "branch": "main"}]}
    s = settings(c)
    expect("a second line is tracked as <app>-<line>", s["follow"]["api-aws"]["branch"] == "main"
           and s["follow"]["api-aws"]["dir"].endswith("/api-aws"))
    c["knowledge"] = {"areas": [{"name": "Bad Name", "apps": ["nope"]}], "grow_on": {"typo": True}}
    try:
        settings(c)
        expect("bad config refused", False, "accepted")
    except ValueError as e:
        m = str(e)
        expect("bad config refused with every problem named", "Bad Name" in m and "'nope'" in m and "typo" in m, m)
    c = json.loads(json.dumps(base)); c["knowledge"] = {"kinds": ["service", {"name": "runbook", "about": "ops steps"}],
                                                       "relations": ["CALLS", {"name": "DEPLOYS_TO"}], "grow_on": {"bug_fix": False}}
    s = settings(c)
    expect("custom kinds/relations/triggers", [k["name"] for k in s["kinds"]] == ["service", "runbook"]
           and [r["name"] for r in s["relations"]] == ["CALLS", "DEPLOYS_TO"] and s["grow_on"]["bug_fix"] is False)
    expect("ignore: vendor and lock files", ignored("a/vendor/x.go", s["ignore"]) and ignored("go.sum", s["ignore"])
           and not ignored("svc/limits.go", s["ignore"]))
    c["tester"] = {"kits_dir": "~/kits"}
    expect("tester kits folder is never read", "~/kits/**" in settings(c)["never_read"])
    p = plan(base)
    expect("plan: cross area lists both apps' sources", [x["key"] for x in p["areas"][2]["sources"]] == ["api", "web"])
    tpl = "{{sources_table}}\n{{areas_table}}\n{{kinds_table}}\n{{relations_table}}\n{{lines_note}}\n{{unknown}}"
    out = render_brief(tpl, base, {"api": "a" * 40})
    expect("brief rendered with pins", "| api | /x/knowledge/src/api | release @ aaaaaaaaaaaa |" in out
           and "not pinned yet" in out and "{{unknown}}" in out, out)
    s = settings(base)
    expect("default relations cover queues, concepts and see-also",
           {"PUBLISHES_TO", "CONSUMES_FROM", "EXPLAINS", "PART_OF", "SEE_ALSO"} <= {r["name"] for r in s["relations"]})
    expect("engram title: AREA · kind · title", engram_title(s, "web-edge", "service", "gw") == "WEB-EDGE · service · gw")
    c = copy.deepcopy(base); c["knowledge"] = {"engram_title": "{area}/{kind}/{title}"}
    expect("engram title format is a setting", engram_title(settings(c), "api", "flow", "pay") == "api/flow/pay")
    c["knowledge"] = {"engram_title": "{AREA} only"}
    try:
        settings(c); expect("engram title without {title} refused", False, "accepted")
    except ValueError as e:
        expect("engram title without {title} refused", "engram_title" in str(e), str(e))
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        r = pathlib.Path(d)
        for sub, marker in (("svc/api", "go.mod"), ("svc/api/internal/x", "go.mod"), ("svc/worker", "Dockerfile"),
                            ("web", "package.json"), ("node_modules/lib", "package.json"), ("tests/fake", "Dockerfile"),
                            ("tools/Gen", "Gen.csproj"), ("lib/Core", "Core.csproj")):
            (r / sub).mkdir(parents=True, exist_ok=True); (r / sub / marker).write_text("x")
        got = detect_services(r)
        expect("services detected: nested markers once, vendor/tests skipped, .csproj counts",
               got == ["lib/Core", "svc/api", "svc/worker", "web"], got)
        for c in ("gw", "bridge"):
            (r / "mcp" / "cmd" / c).mkdir(parents=True, exist_ok=True)
        (r / "mcp" / "go.mod").write_text("x")
        expect("a module with several cmd/<name> programs gives one service each",
               {"mcp/cmd/gw", "mcp/cmd/bridge"} <= set(detect_services(r)) and "mcp" not in detect_services(r), detect_services(r))
        (r / "deployments" / "k8s").mkdir(parents=True); (r / "deployments" / "k8s" / "Dockerfile").write_text("x")
        expect("deployment folders are not services", "deployments/k8s" not in detect_services(r), detect_services(r))
        (r / ".github" / "workflows").mkdir(parents=True); (r / "scripts").mkdir(exist_ok=True)
        (r / "scripts" / "deploy-dev.sh").write_text("x")
        df = detect_deploy_files(r)
        expect("deploy files: deploy folders, CI workflows, root Dockerfile-level files, deploy scripts",
               "deployments/" in df and ".github/workflows/" in df and "scripts/deploy-dev.sh" in df, df)
        (r / "one").mkdir(); (r / "one" / "main.go").write_text("x"); (r / "one" / "go.mod").write_text("x")
        expect("a repo whose root is the service is one service", detect_services(r / "one") == ["."], detect_services(r / "one"))
        for c in ("gateway", "worker"):
            (r / "one" / "cmd" / c).mkdir(parents=True)
        expect("a root module with several cmd/<name> programs gives one service each",
               detect_services(r / "one") == ["cmd/gateway", "cmd/worker"], detect_services(r / "one"))
    print("ALL PASS" if not bad else f"{bad} FAILED")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    if sys.argv[1:] == ["plan"]:
        print(json.dumps(plan(pairconf.load()), indent=1))
        sys.exit(0)
    sys.exit("usage: kb.py plan | --selftest")
