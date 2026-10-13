"""Shared by action-ledger.py and deploy-gate.py — one place for masking, the tester's privacy rule and
categories, so the two ledger writers can never disagree. Ledger folder and role come from pair.yaml."""
import datetime, json, os, pathlib, re, socket, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib"))
CFG_ERROR = None
try:
    import pairconf
except BaseException:          # kit not installed here: entries are built but not written
    pairconf = None
try:
    CFG = pairconf.load() if pairconf else None
except BaseException as _e:
    CFG = None
    try:                       # a pair.yaml that exists but cannot load is not "no pair here": keep writing, privately
        if pairconf.find_config() is not None:
            CFG_ERROR = str(_e)[:200]
    except BaseException:
        pass

MASKS = [
    (re.compile(r"(odts_|gh[pousr]_|github_pat_|xox[abposr]-|sk-ant-|AKIA|ASIA)[A-Za-z0-9._/+=-]{6,}"), r"\1<MASKED>"),
    (re.compile(r"eyJ[A-Za-z0-9_-]{6,}(\.[A-Za-z0-9_-]+){0,2}"), "eyJ<MASKED>"),
    (re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"), r"\1 <MASKED>"),
    (re.compile(r"://[^/\s:@]+:[^@\s/]+@"), "://<MASKED>@"),                       # https://user:pw@host
    (re.compile(r"(?i)(-u|--user)\s+[^\s:]+:\S+"), r"\1 <MASKED>"),                 # curl -u user:pw
    (re.compile(r"(?i)(--?(?:password|passwd|pwd|token|secret|api-?key|client-secret)[=\s]+)\S+"), r"\1<MASKED>"),
    (re.compile(r"(?i)\"(password|passwd|secret|token|api_?key|client_secret|pat)\"\s*:\s*\"[^\"]*\""), r'"\1": "<MASKED>"'),
    (re.compile(r"(?i)\b([A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_?KEY|_PAT|_KEY))\s*=\s*\S+"), r"\1=<MASKED>"),
    (re.compile(r"(?i)\b(password|passwd|pwd|secret|token|apikey|api_key)\s*[=:]\s*\S+"), r"\1=<MASKED>"),
    (re.compile(r"(?i)(x-[\w-]*(?:secret|token|key)[\w-]*\s*:\s*)\S+"), r"\1<MASKED>"),
    # v3 — the 16 shapes the third review leaked (2026-10-10)
    (re.compile(r"(?i)(--from-literal=[^=\s]+=)\S+"), r"\1<MASKED>"),                     # any k8s literal
    (re.compile(r"(?i)(\bsshpass\s+-p\s*)\S+"), r"\1<MASKED>"),
    (re.compile(r"(?i)(\b(?:mysql|mariadb)\b[^|;&\n]*?\s-p)(?!\s)\S+"), r"\1<MASKED>"),    # mysql -pX
    (re.compile(r"(?i)(\s-p\s+)(?=[^-\s])\S+(?=.*\b(?:docker|podman|az|helm|oras)\b)|(\b(?:docker|podman|helm|oras)\s+(?:registry\s+)?login\b[^|;&\n]*?\s-p\s+)\S+"), lambda m: (m.group(1) or m.group(2)) + "<MASKED>"),
    (re.compile(r"(?i)(\baz\s+login\b[^|;&\n]*?\s(?:-p|--password)\s+)\S+"), r"\1<MASKED>"),
    (re.compile(r"(?i)(\bredis-cli\b[^|;&\n]*?\s-a\s+)\S+"), r"\1<MASKED>"),
    (re.compile(r"(?i)(\baws\s+configure\s+set\s+\S*(?:secret|token|key)\S*\s+)\S+"), r"\1<MASKED>"),
    (re.compile(r"(?i)\b((?:api-?key|ocp-apim-subscription-key|subscription-key|cookie|set-cookie|authorization)\s*:\s*)[^'\"\n]+"), r"\1<MASKED>"),
    (re.compile(r"(?i)\b(AccountKey|SharedAccessKey|Password|Pwd)=[^;'\"\s]+"), r"\1=<MASKED>"),   # connection strings
    (re.compile(r"(?i)([?&]sig=)[^&'\"\s]+"), r"\1<MASKED>"),                              # SAS signature
    (re.compile(r"(?i)\b(export\s+)?([A-Z][A-Z0-9_]*(?:PASS|PASSPHRASE|PWD|CRED|AUTH)[A-Z0-9_]*)\s*=\s*\S+"), lambda m: (m.group(1) or "") + m.group(2) + "=<MASKED>"),
    (re.compile(r"(?i)\b(pw|pwd|pass|password|passphrase|secret|token)\s+(is|=|:)\s+\S+"), r"\1 \2 <MASKED>"),   # prose
]


def mask(s):
    s = s or ""
    for rx, rep in MASKS:
        s = rx.sub(rep, s)
    return s


def _test_dir():
    """Self-tests only: PAIR_LEDGER_DIR under /tmp may stand in for the ledger (and allow a role override)."""
    d = os.environ.get("PAIR_LEDGER_DIR", "")
    return d if d.startswith("/tmp/") else ""


def agent_name():
    """'builder' | 'tester' | 'unknown' — from hostname via pair.yaml (never from an env var an agent sets)."""
    if _test_dir() and os.environ.get("PAIR_LEDGER_TEST_ROLE") in ("builder", "tester"):
        return os.environ["PAIR_LEDGER_TEST_ROLE"]
    return pairconf.role(CFG) if CFG else "unknown"


def bash_category(cmd):
    """Category from the FULL command (not the tester's redacted summary, which would hide e.g. a git push)."""
    c = re.sub(r"\\\n", " ", cmd or "")
    if re.search(r"\b(kubectl|oc|helm)\b[^|;&\n]*\b(apply|create|replace|patch|edit|delete|scale|autoscale|expose|set|run|debug|cp|label|annotate|cordon|uncordon|drain|taint|certificate|rollout\s+(?:restart|undo)|install|upgrade|uninstall|rollback)\b", c) \
            and "--dry-run=client" not in c and "--dry-run=server" not in c:
        return "cluster-write"
    if re.search(r"kubernetes\.default\.svc|\baz\s+aks\b|\bterraform\s+apply\b", c):
        return "cluster-write"
    if re.search(r"\b(kubectl|oc|helm)\b", c):
        return "cluster-read"
    if re.search(r"\bgh\s+workflow\s+run\b", c):
        return "ci-trigger"
    if re.search(r"\b(buildctl|crane|docker\s+push|az\s+acr)\b", c):
        return "build-push"
    if re.search(r"\bgit\b[^|;&\n]*\bpush\b", c):
        return "git-push"
    if re.search(r"\bgit\b[^|;&\n]*\bcommit\b", c):
        return "git-commit"
    if re.search(r"\bgh\s+(pr\b|api\b[^|;&\n]*-X\s*(PATCH|POST)[^|;&\n]*pulls)", c):
        return "pr"
    if re.search(r"\bargus[\w.-]*\.sh\b|\bargus\s", c):
        return "argus"
    return "other"


def tool_category(tool, ti):
    if tool == "Bash":
        return bash_category(ti.get("command", ""))
    if tool in ("Edit", "Write", "NotebookEdit"):
        return "file-edit"
    if tool in ("Read", "Grep", "Glob"):
        return "read"
    if tool == "Agent":
        return "agent"
    if re.search(r"(send_channel_message|reply_channel_message|send_chat_message|slack_send|send_email|reply_email)", tool):
        return "outbound-post"
    if re.search(r"confluence_(create|update|append|prepend|add)", tool):
        return "confluence-write"
    if re.search(r"jira_(create|update|transition|add_comment|set_labels|add_labels|remove|add_worklog|delete)", tool):
        return "jira-write"
    if re.search(r"engram_(write|update|delete|create)", tool):
        return "memory-write"
    if re.search(r"runner__|author__", tool):
        return "argus"
    return "other"


ID_KEYS = ("channel_id", "message_id", "issue_key", "issueKey", "key", "project_key", "page_id",
           "space_key", "repo", "instance_id", "run_id", "collection", "namespace")


def summary(tool, ti, agent):
    tester = agent == "tester"     # the tester's arguments can be expected values: program names only
    if tool == "Bash":
        cmd = re.sub(r"\\\n", " ", (ti.get("command") or "").strip())
        first = (cmd.splitlines()[0] if cmd else "")[:240]
        if tester:   # an argument can be an expected value: the first PROGRAM only, never an
            # env assignment before it (v2 logged `PGPASSWORD=X …` and `EXPECTED_TOTAL=43 …`)
            toks = [t for t in first.split() if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t)]
            return (os.path.basename(toks[0]) if toks else "") + " …"
        return mask(first)
    if tool in ("Edit", "Write", "Read", "NotebookEdit"):
        return ti.get("file_path", "")
    if tool in ("Grep", "Glob"):
        return ("<pattern hidden> in " if tester else f'{ti.get("pattern", "")} in ') + str(ti.get("path", "") or ".")
    if tool == "Agent":
        return ti.get("subagent_type", "general") + ("" if tester else ": " + mask(ti.get("description", "")))
    if tool == "NotebookEdit":
        return ti.get("notebook_path", "")
    ids = {k: ti[k] for k in ID_KEYS if k in ti}
    extra = "" if tester else " " + mask(str(ti.get("subject") or ti.get("title") or ti.get("summary") or "")[:120])
    return (json.dumps(ids) + extra).strip()[:240]


def fallback_dir():
    """Where entries go while pair.yaml cannot load (the shared ledger's path is in it): this home folder."""
    return pathlib.Path.home() / ".cache" / "builder-tester-agents" / "ledger-fallback"


def ledger_path():
    if _test_dir():
        return pathlib.Path(_test_dir())
    if CFG:
        return pairconf.ledger_dir(CFG)
    return fallback_dir() if CFG_ERROR else None


def write(entry):
    try:
        d = ledger_path()
        if d is None:
            return
        d.mkdir(parents=True, exist_ok=True)
        day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
        with open(d / f"{day}.jsonl", "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


def entry(ev, phase, **extra):
    tool = ev.get("tool_name", "")
    ti = ev.get("tool_input") or {}
    agent = agent_name()
    e = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
         "agent": agent, "name": (pairconf.name(CFG, agent) if CFG and agent in ("builder", "tester") else agent),
         "host": socket.gethostname(), "workspace": os.environ.get("CODER_WORKSPACE_NAME", ""),
         "session": ev.get("session_id", ""), "id": ev.get("tool_use_id", ""), "phase": phase,
         "tool": tool, "category": tool_category(tool, ti),
         # role unknown while pair.yaml cannot load: log as privately as the tester (program names only)
         "summary": summary(tool, ti, "tester" if CFG_ERROR else agent)}
    if CFG_ERROR:
        e["config_error"] = CFG_ERROR
    # which session: the agent the kit started (start-agent.sh sets PAIR_AGENT_SESSION) or another Claude session on the
    # same workspace (a person's own session). Informational only — never used to grant anything.
    e["session_kind"] = "agent" if os.environ.get("PAIR_AGENT_SESSION") else "other-session"
    if phase == "done":
        r = ev.get("tool_response")
        bad = isinstance(r, dict) and (r.get("is_error") or r.get("error") or r.get("isError"))
        e["ok"] = not bad
    e.update(extra)
    return e
