#!/usr/bin/env python3
"""secret-guard.py — keep credential VALUES out of session transcripts, by mechanism.

A rule that says "never print a secret" depends on every agent remembering it on every call.
Whatever a tool prints becomes a stored transcript, and transcripts are copied, synced and
sometimes committed, so one slip becomes many copies. This hook sits between the tools and the
transcript instead. One file, several entry points:

  Claude Code hook events (JSON on stdin, dispatched on hook_event_name):
    PreToolUse  (matcher Bash)   DENY the known dump commands (the reason names a safe form), in
                                 every permission mode. In bypassPermissions only, REWRITE every
                                 other foreground command so its stdout and stderr pass through
                                 the redactor (--filter). The rewrite carries no permissionDecision.
                                 ⚠️ Why bypassPermissions only: in the other modes Claude Code
                                 matches permission rules against the rewritten command, so
                                 allow-listed commands stop matching (measured: a dontAsk session
                                 was denied every Bash call). Outside it, output is NOT redacted.
    PostToolUse (matcher mcp__.*) mask the same values in MCP tool output
                                 (hookSpecificOutput.updatedMCPToolOutput).
    UserPromptSubmit             block a prompt that carries a token-shaped string or the exact
                                 value of a secret in the environment, so it never reaches the
                                 model. ⚠️ Claude Code itself appends "Original prompt: …" to its
                                 block notice and stores that notice in the session file, so the
                                 value is kept from the model and the API, NOT from the local
                                 transcript. The reason text here never repeats it.

  Command-line modes:
    --filter                     stdin -> stdout, redacted line by line (the Bash rewrite's sink)
    --pre-commit                 git pre-commit: re-redact staged session journals in place,
                                 refuse any other staged secret (file:line + rule, never the
                                 value); also runs gitleaks with the generated config when it
                                 is installed
    --install-precommit <repo>   install the pre-commit shim into <repo>, keeping any existing
                                 hook as pre-commit.local and running it afterwards (idempotent)
    --gitleaks-config            print a gitleaks config built from the SAME rule table

What is redacted:
  1. the CURRENT values of environment variables whose NAME says secret (TOKEN, SECRET,
     PASSWORD, PASSPHRASE, API_KEY, PRIVATE_KEY, ACCESS_KEY, CREDENTIAL, *_PAT, *_KEY), in raw
     and base64 form, so a value is caught whatever its shape and whatever printed it;
  2. known token shapes (RULES below), PEM private-key blocks, and the password in a
     scheme://user:pass@host URL;
  3. a value under a secret-named key in JSON or in a KEY=value assignment.

Limits, stated so nobody reads more into it: a secret that is not in this process's
environment, has no known shape and sits under no telling key is not caught. The deny list is
a list; the redactor is the backstop behind it, and the pre-commit and a periodic scan are the
backstops behind that.

Kill switch for one session: SECRET_GUARD=off in the environment Claude Code was started with.
The Bash rewrite alone: SECRET_GUARD_WRAP=off.
"""
import base64
import json
import os
import re
import shlex
import subprocess
import sys
import urllib.parse

MARKER = "# secret-guard: output is redacted"
PRECOMMIT_MARKER = "secret-guard pre-commit"

# ── the rule table: one source for the redactor, the prompt check, the pre-commit scan and the
# ── generated gitleaks config. Every regex is RE2-compatible (no look-around) so gitleaks,
# ── which is Go, can use it verbatim.
RULES = [
    ("synapse-pat", r"syn_[A-Za-z0-9]{32,}", "Synapse personal access token"),
    ("github-token", r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})", "GitHub token"),
    ("slack-token", r"xox[abposr]-[A-Za-z0-9-]{10,}", "Slack token"),
    ("slack-app-token", r"xapp-[0-9]+-[A-Za-z0-9-]{10,}", "Slack app-level token"),
    ("stripe-live-key", r"(?:sk|rk)_live_[A-Za-z0-9]{16,}", "Stripe live key"),
    ("openai-key", r"sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}", "OpenAI-style secret key"),
    ("supabase-secret-key", r"sb_secret_[A-Za-z0-9_-]{16,}", "Supabase secret key"),
    ("aws-access-key-id", r"(?:AKIA|ASIA)[0-9A-Z]{16}", "AWS access key id"),
    ("jwt", r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}", "JSON Web Token"),
    ("coder-token", r"\b[A-Za-z0-9]{10}-[A-Za-z0-9]{22}\b", "Coder session/agent token"),
]
# the password inside scheme://user:password@host — the user and host are kept
URL_PW_RE = r"((?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|amqps?|rediss?)://[^:/@\s\"']+:)([^@\s\"']+)(@)"
PEM_BEGIN = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")
PEM_END = re.compile(r"-----END [A-Z0-9 ]*PRIVATE KEY-----")

_COMPILED = [(rid, re.compile(rx)) for rid, rx, _ in RULES]
_URL_PW = re.compile(URL_PW_RE)
_BEARER = re.compile(r"(\b[Bb]earer\s+)[A-Za-z0-9._~+/-]{12,}=*")
# a secret-named key followed by a value, in JSON ("token": "v") or assignment (API_TOKEN=v)
_SECRET_KEY = r"[A-Za-z0-9_.-]*(?:token|secret|password|passwd|passphrase|api[_-]?key|apikey|private[_-]?key|access[_-]?key|client[_-]?secret|credentials?)"
_JSON_KV = re.compile(r'("' + _SECRET_KEY + r'"\s*:\s*")([^"\\]{8,})(")', re.I)
_ASSIGN_KV = re.compile(r"(?<![A-Za-z0-9_])(" + _SECRET_KEY + r")(\s*=\s*[\"']?)([^\s\"'&;]{8,})", re.I)
# keys that end in "token" but hold pagination state, not credentials — masking them breaks paging
_NOT_SECRET_KEY = re.compile(r"page|cursor|continuation|next|count|type|usage|limit|max|input|output|total", re.I)

REDACTED = "[REDACTED]"


# ── the environment's own secrets ──────────────────────────────────────────────────────────────
_SECRET_NAME = re.compile(
    r"TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY|CREDENTIAL|(?:^|_)PAT(?:$|_)|(?:^|_)KEY$",
    re.I,
)
_NOT_SECRET_NAME = re.compile(r"^(?:SSH_AUTH_SOCK|GPG_AGENT_INFO|.*_KEY_ID|.*_KEYRING|.*_TOKEN_FILE|.*_KEY_FILE|.*_PATH)$", re.I)


def _looks_like_value(v):
    if len(v) < 8 or v.lower() in ("true", "false", "null", "none", "changeme"):
        return False
    if v.startswith(("/", "~", "./", "http://localhost")) or v.isdigit():
        return False
    return True


def env_secret_values(env=None):
    """The current values of secret-named env vars, plus the encodings a tool is likely to print."""
    env = os.environ if env is None else env
    vals = set()
    for k, v in env.items():
        if not v or not _SECRET_NAME.search(k) or _NOT_SECRET_NAME.match(k):
            continue
        v = v.strip()
        if not _looks_like_value(v):
            continue
        vals.add(v)
        for raw in (v, v + "\n"):
            b = base64.b64encode(raw.encode()).decode()
            vals.add(b)
            vals.add(b.rstrip("="))
        q = urllib.parse.quote(v, safe="")
        if q != v:
            vals.add(q)
    return sorted((x for x in vals if len(x) >= 8), key=len, reverse=True)


def _values_re(values):
    return re.compile("|".join(re.escape(v) for v in values)) if values else None


class Redactor:
    def __init__(self, env=None):
        self.values_re = _values_re(env_secret_values(env))
        self.in_pem = False

    def line(self, s):
        """Redact one line. Stateful only for PEM blocks, which span lines."""
        if self.in_pem:
            if PEM_END.search(s):
                self.in_pem = False
            return None  # swallowed; the BEGIN line already printed the marker
        if PEM_BEGIN.search(s):
            self.in_pem = not PEM_END.search(s)
            return PEM_BEGIN.split(s)[0] + "[REDACTED PRIVATE KEY]"
        return self.text(s)

    def text(self, s):
        if self.values_re is not None:
            s = self.values_re.sub(REDACTED, s)
        for _, rx in _COMPILED:
            s = rx.sub(REDACTED, s)
        s = _URL_PW.sub(lambda m: m.group(1) + REDACTED + m.group(3), s)
        s = _BEARER.sub(lambda m: m.group(1) + REDACTED, s)
        s = _JSON_KV.sub(lambda m: m.group(0) if _skip_kv(m.group(1), m.group(2)) else m.group(1) + REDACTED + m.group(3), s)
        s = _ASSIGN_KV.sub(lambda m: m.group(0) if _skip_kv(m.group(1), m.group(3)) else m.group(1) + m.group(2) + REDACTED, s)
        return s

    def block(self, s):
        out = []
        for ln in s.split("\n"):
            r = self.line(ln)
            if r is not None:
                out.append(r)
        return "\n".join(out)


def _skip_kv(key, val):
    key = key.strip('"')
    if _NOT_SECRET_KEY.search(key.rsplit("_", 1)[0] if key.lower().endswith("token") else ""):
        return True
    if REDACTED in val or val.startswith(("${", "$", "<", "EV[", "{{", "/", "./", "~/")) or val.isdigit():
        return True
    return False


def findings(text, env=None, values_re=None):
    """Rule ids (never values) found in text: known shapes, URL passwords, PEM keys, env values."""
    hits = []
    for rid, rx in _COMPILED:
        if rx.search(text):
            hits.append(rid)
    if _URL_PW.search(text):
        hits.append("url-password")
    if PEM_BEGIN.search(text):
        hits.append("private-key")
    vre = values_re if values_re is not None else _values_re(env_secret_values(env))
    if vre is not None and vre.search(text):
        hits.append("env-secret-value")
    return hits


# ── PreToolUse(Bash): the deny list ─────────────────────────────────────────────────────────────
KUBECTL_NAMES = "kubectl get secret <name> -n <ns> -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}'"
MSG = {
    "kubectl": "This prints Secret VALUES (base64 is an encoding, not encryption), and whatever a command prints is stored in the session transcript. Key names only: " + KUBECTL_NAMES + " . Existence and sizes: kubectl describe secret <name> -n <ns>.",
    "doctl": "This prints the app spec, and DigitalOcean env values of type GENERAL are plain text in it. Names and types only: doctl apps spec get <id> | jq '[.. | .envs? // empty | .[] | {key, type}]'.",
    "gh-token": "This prints the GitHub token itself. To check a login: gh auth status (without -t). To use it, let gh send it (gh api ...) or rely on GH_TOKEN already in the environment; never print it.",
    "env": "This prints every environment variable's VALUE, tokens included. Names only: env | cut -d= -f1 . One variable set or not: test -n \"$NAME\" and echo the result.",
    "dotenv": "A .env file holds credential values. Names only: cut -d= -f1 <file> . A template without values (.env.example) is fine to read.",
    "proc-environ": "This prints a process's environment, tokens included. Names only: tr '\\0' '\\n' < /proc/<pid>/environ | cut -d= -f1 .",
    "vault": "This prints secret values. Read one field with -field=<key> and pipe it straight into its consumer (vault kv get -field=<key> <path> | kubectl create secret generic <name> --from-file=<key>=/dev/stdin), or check existence with vault kv metadata get <path>.",
    "az": "This prints the secret value. Names only: az keyvault secret list --vault-name <kv> --query '[].name' -o tsv .",
    "op": "This prints the secret to the terminal. Pipe it into its consumer, write it with --out-file, or use op run -- <cmd>, which injects secrets as env and masks them in output.",
}
READERS = {"cat", "less", "more", "head", "tail", "bat", "batcat", "nl", "tac", "strings", "xxd", "od",
           "hexdump", "grep", "egrep", "fgrep", "rg", "ag", "sed", "awk", "gawk", "sort", "uniq", "base64", "jq", "yq"}
WRAPPERS = {"sudo", "command", "exec", "time", "nohup", "nice", "stdbuf", "doas"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
DOTENV = re.compile(r"(?:^|/)\.env(?:$|[.\-_][^/]*$)")
DOTENV_SAFE = re.compile(r"(?:example|sample|template|dist|defaults?|schema)$", re.I)


def _tokens(cmd):
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|<>\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def _structure(cmd):
    """-> list of pipelines; a pipeline is a list of stages; a stage is (argv, stdout_redirected)."""
    toks = _tokens(cmd)
    pipelines, stages, argv, redir = [], [], [], False
    i = 0
    while i < len(toks):
        t = toks[i]
        if t in ("|", "|&"):
            stages.append((argv, redir)); argv, redir = [], False
        elif t in (";", "&", "&&", "||", "\n", ";;", "&;"):
            if argv or stages:
                stages.append((argv, redir)); pipelines.append(stages)
            stages, argv, redir = [], [], False
        elif t in (">", ">>", ">|", "&>", "&>>"):
            fd = argv[-1] if argv and argv[-1].isdigit() else None
            nxt = toks[i + 1] if i + 1 < len(toks) else ""
            if fd and fd != "1":
                argv = argv[:-1]  # 2>... : stderr only, stdout still reaches the transcript
            elif nxt == "&":
                argv = argv[:-1] if fd else argv  # >&2 and friends: not a file
            else:
                if fd:
                    argv = argv[:-1]
                redir = True
            i += 2 if nxt not in ("&",) else 3
            continue
        elif t in ("<", "<<", "<<<"):
            i += 2
            continue
        else:
            argv.append(t)
        i += 1
    if argv or stages:
        stages.append((argv, redir)); pipelines.append(stages)
    return pipelines


def _strip_prefix(argv):
    """Drop VAR=val prefixes and transparent wrappers. Returns (argv, was_bare_env)."""
    a = list(argv)
    while a:
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", a[0]):
            a = a[1:]
        elif a[0] in WRAPPERS:
            a = a[1:]
        elif a[0] == "timeout" and len(a) > 1:
            a = a[2:] if not a[1].startswith("-") else a[1:]
        elif a[0] == "env":
            rest = a[1:]
            while rest and (rest[0].startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", rest[0])):
                rest = rest[2:] if rest[0] in ("-u", "--unset", "-C", "--chdir", "-S") else rest[1:]
            if not rest:
                return ["env"], True
            a = rest
        else:
            break
    return a, False


def _names_only(stage):
    """True when a pipeline stage keeps only the part before '=' (names, not values)."""
    if not stage:
        return False
    argv = stage[0]
    if not argv:
        return False
    j = " ".join(argv)
    if argv[0] == "cut" and re.search(r"-d\s*=|-d\s*'='|--delimiter=?=", j) and re.search(r"-f\s*1\b|--fields=?1\b", j):
        return True
    if argv[0] in ("awk", "gawk") and re.search(r"-F\s*=|-F'='", j) and re.search(r"print \$1\s*}", j):
        return True
    if argv[0] == "sed" and re.search(r"s/=\.\*//", j):
        return True
    return False


def _opt(argv, *names):
    """Value of -o/--output style options (both 'x' and '-o=x' / '--output=x' / '-ox' forms)."""
    for i, t in enumerate(argv):
        for n in names:
            if t == n and i + 1 < len(argv):
                return argv[i + 1]
            if t.startswith(n + "="):
                return t[len(n) + 1:]
            if len(n) == 2 and t.startswith(n) and len(t) > 2 and not t.startswith("--"):
                return t[2:]
    return None


def _kubectl(argv):
    if "get" not in argv:
        if "create" in argv and "secret" in argv:
            fmt = _opt(argv, "-o", "--output") or ""
            return "kubectl" if fmt.split("=")[0] in ("yaml", "json") else None
        return None
    rest = argv[argv.index("get") + 1:]
    res = next((t for t in rest if not t.startswith("-")), "")
    kinds = {r.split("/")[0].lower() for r in res.split(",")}
    if not kinds & {"secret", "secrets"}:
        return None
    joined = " ".join(argv)
    fmt = _opt(argv, "-o", "--output")
    if fmt is None and "--template" not in joined:
        return None
    fmt = fmt or ""
    kind = fmt.split("=", 1)[0]
    if kind in ("name", "wide"):
        return None
    if kind.startswith("go-template") and "=" in fmt:
        tpl = fmt.split("=", 1)[1]
        m = re.search(r"range\s+\$(\w+)\s*,\s*\$(\w+)\s*:=\s*\.data\b", tpl)
        if m and len(re.findall(r"\$" + m.group(2) + r"\b", tpl)) == 1 and "index" not in tpl and ".data." not in tpl:
            return None
    return "kubectl"


def _rule_for(argv, piped, redirected):
    """Deny-rule key for one simple command, or None."""
    if not argv:
        return None
    a, bare_env = _strip_prefix(argv)
    if bare_env:
        return "env"
    if not a:
        return None
    c = os.path.basename(a[0])
    joined = " ".join(a)
    if c in SHELLS:
        for i, t in enumerate(a[1:], 1):
            if t.startswith("-") and "c" in t.lstrip("-") and not t.startswith("--") and i + 1 < len(a):
                return deny_reason(a[i + 1], nested=True)
        return None
    if c == "eval":
        return deny_reason(" ".join(a[1:]), nested=True)
    if c == "ssh":
        cmdargs = [t for t in a[1:] if not t.startswith("-")][1:]
        return deny_reason(" ".join(cmdargs), nested=True) if cmdargs else None
    if c == "kubectl":
        if "exec" in a and "--" in a:
            return deny_reason(shlex.join(a[a.index("--") + 1:]), nested=True)
        return _kubectl(a)
    if c == "gh":
        if a[1:3] == ["auth", "token"]:
            return "gh-token"
        if a[1:3] == ["auth", "status"] and ({"-t", "--show-token"} & set(a)):
            return "gh-token"
        return None
    if c == "printenv":
        return "env"
    if c in ("set", "export", "declare", "typeset") and (len(a) == 1 or a[1:] in (["-p"], ["-x"], ["-px"], ["-xp"])):
        return "env" if c != "set" or len(a) == 1 else None
    if c == "doctl":
        fmt = _opt(a, "-o", "--output")
        if fmt and fmt.lower().startswith("json"):
            return "doctl"
        if "apps" in a:
            i = a.index("apps")
            if a[i + 1:i + 2] == ["get"]:
                return "doctl"
            if a[i + 1:i + 3] == ["spec", "get"] and not piped and not redirected:
                return "doctl"
        return None
    if c == "vault":
        if a[1:3] == ["kv", "get"] or a[1:2] == ["read"]:
            if not any(t == "-field" or t.startswith("-field=") for t in a):
                return "vault"
            return None if (piped or redirected) else "vault"
        return None
    if c == "az" and a[1:4] == ["keyvault", "secret", "show"]:
        return "az"
    if c == "op":
        if a[1:2] == ["read"] and not (piped or redirected or "--out-file" in a or "-o" in a):
            return "op"
        if a[1:3] == ["item", "get"] and "--reveal" in a:
            return "op"
        return None
    if c in READERS:
        paths = [t for t in a[1:] if not t.startswith("-")]
        if any("/proc/" in p and p.endswith("/environ") for p in paths):
            return "proc-environ"
        if c in ("grep", "egrep", "fgrep", "rg") and re.search(r"(?:^|\s)-[a-zA-Z]*[clLq]", joined):
            return None
        if any(DOTENV.search(p) and not DOTENV_SAFE.search(p) for p in paths):
            return "dotenv"
    return None


def deny_reason(cmd, nested=False):
    """The deny-rule key for a whole command line, or None."""
    try:
        pipelines = _structure(cmd)
    except ValueError:
        return _raw_fallback(cmd)
    for stages in pipelines:
        for idx, (argv, redir) in enumerate(stages):
            nxt = stages[idx + 1] if idx + 1 < len(stages) else None
            key = _rule_for(argv, piped=nxt is not None, redirected=redir)
            if key in ("env",) and nxt is not None and _names_only(nxt):
                continue
            if key:
                return key
    return None


def _raw_fallback(cmd):
    """Unparseable (unbalanced quotes): judge the raw text, conservatively."""
    for rx, key in ((r"\bgh\s+auth\s+token\b", "gh-token"), (r"\bkubectl\b.*\bsecrets?\b.*(-o|--output)", "kubectl"),
                    (r"\bdoctl\s+apps\s+get\b", "doctl"), (r"(^|[\s;|&(])(env|printenv)(\s*$|\s*[|;&])", "env")):
        if re.search(rx, cmd):
            return key
    return None


def _wrap(cmd):
    """The original command, with its stdout+stderr captured to a private temp file and filtered
    when it finishes.

    ⛔ SYNCHRONOUS ON PURPOSE. The first version redirected into async `>( filter )` processes. It
    passed every test that read the output through a pipe, and in a live session returned EMPTY
    output: Claude Code reads the command's output when the shell exits, and the filters were still
    flushing. Capture-then-filter has nothing in flight at exit. It costs streaming, which a
    foreground Bash call never shows anyway (background calls are not rewritten).
    Portable to bash 3.2 and zsh (no process substitution, no `wait` on one). No subshell, so a cd
    in the command still moves the session. An `exit` inside the command runs the EXIT trap, which
    delivers the output; otherwise the tail does it and restores the exit status.
    """
    g = shlex.quote(os.path.abspath(__file__))
    return (
        f"{MARKER} (secret-guard.py); the original command follows unchanged\n"
        '__sg_f="$(mktemp "${TMPDIR:-/tmp}/secret-guard.XXXXXX")"; '
        f'__sg_end() {{ exec 1>&3 2>&4; python3 {g} --filter < "$__sg_f"; rm -f "$__sg_f"; }}; '
        'trap __sg_end EXIT; exec 3>&1 4>&2 >"$__sg_f" 2>&1\n'
        f"{cmd}\n"
        '__sg_rc=$?; trap - EXIT; __sg_end; (exit $__sg_rc)'
    )


# ── hook entry points ────────────────────────────────────────────────────────────────────────────
def on_pre_tool_use(ev):
    if ev.get("tool_name") != "Bash":
        return {}
    ti = ev.get("tool_input") or {}
    cmd = ti.get("command") or ""
    if not cmd.strip() or MARKER in cmd:
        return {}
    key = deny_reason(cmd)
    if key:
        reason = "secret-guard: denied. " + MSG[key]
        return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                       "permissionDecisionReason": reason}}
    if os.environ.get("SECRET_GUARD_WRAP", "on").lower() == "off":
        return {}
    # ⛔ ONLY in bypassPermissions. MEASURED in a live headless session: in every other mode Claude
    # Code matches permission rules against the REWRITTEN command, so an allow-listed command stops
    # matching -- a dontAsk worker was denied every Bash call, including ones the same session ran
    # without the hook. In bypassPermissions no allow rule is consulted, and deny rules were measured
    # still to catch the original line inside the wrapper. Outside it, the deny list above still
    # applies; the output is not redacted.
    if ev.get("permission_mode") != "bypassPermissions" or ti.get("run_in_background"):
        return {}
    new = dict(ti)
    new["command"] = _wrap(cmd)
    # ⚠️ NO permissionDecision on purpose: a rewrite must not approve a command that the
    # permission mode would otherwise ask about. The normal permission flow still applies.
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": new}}


def _redact_obj(o, r):
    if isinstance(o, str):
        return r.block(o)
    if isinstance(o, list):
        return [_redact_obj(x, r) for x in o]
    if isinstance(o, dict):
        out = {}
        for k, v in o.items():
            if isinstance(v, str) and re.fullmatch(_SECRET_KEY, k, re.I) and not _skip_kv(k, v) and len(v) >= 8:
                out[k] = REDACTED
            else:
                out[k] = _redact_obj(v, r)
        return out
    return o


def on_post_tool_use(ev):
    if not str(ev.get("tool_name", "")).startswith("mcp__"):
        return {}
    resp = ev.get("tool_response")
    if resp is None:
        return {}
    new = _redact_obj(resp, Redactor())
    if new == resp:
        return {}
    return {"hookSpecificOutput": {"hookEventName": "PostToolUse", "updatedMCPToolOutput": new}}


def on_user_prompt(ev):
    p = ev.get("prompt") or ""
    hits = findings(p)
    if not hits:
        return {}
    reason = ("secret-guard: this prompt was NOT sent, because it contains what looks like a credential ("
              + ", ".join(sorted(set(hits))) + "). Remove it and send again. To hand a secret to a tool, put it "
              "in the environment or the secret store and name the variable, never the value.")
    return {"decision": "block", "reason": reason}


# ── pre-commit ───────────────────────────────────────────────────────────────────────────────────
def _git(args, repo, inp=None):
    return subprocess.run(["git", "-C", repo] + args, input=inp, capture_output=True)


def _is_journal(path):
    parts = path.split("/")
    return path.endswith(".jsonl") and "sessions" in parts[:-1]


def pre_commit():
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if top.returncode != 0:
        return 0
    repo = top.stdout.strip()
    staged = _git(["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"], repo).stdout.decode().split("\0")
    staged = [s for s in staged if s]
    values_re = _values_re(env_secret_values())
    problems, cleaned = [], []
    for path in staged:
        blob = _git(["show", ":" + path], repo).stdout
        if b"\0" in blob[:8192]:
            continue
        text = blob.decode("utf-8", "surrogateescape")
        if _is_journal(path):
            new = Redactor().block(text)
            if new != text:
                sha = _git(["hash-object", "-w", "--stdin"], repo, new.encode("utf-8", "surrogateescape")).stdout.decode().strip()
                mode = _git(["ls-files", "-s", "--", path], repo).stdout.decode().split(" ")[0] or "100644"
                _git(["update-index", "--cacheinfo", f"{mode},{sha},{path}"], repo)
                wt = os.path.join(repo, path)
                try:
                    with open(wt, encoding="utf-8", errors="surrogateescape") as f:
                        cur = f.read()
                    with open(wt, "w", encoding="utf-8", errors="surrogateescape") as f:
                        f.write(Redactor().block(cur))
                except OSError:
                    pass
                cleaned.append(path)
                text = new
        for n, line in enumerate(text.split("\n"), 1):
            for rid in findings(line, values_re=values_re):
                problems.append(f"{path}:{n}: {rid}")
    for p in cleaned:
        print(f"secret-guard: redacted credential(s) in the session journal {p} and re-staged it", file=sys.stderr)
    rc_gl = _gitleaks(repo)
    if problems or rc_gl:
        print("secret-guard: COMMIT REFUSED -- a staged file contains what looks like a credential.", file=sys.stderr)
        for p in problems[:50]:
            print("  " + p, file=sys.stderr)
        if rc_gl:
            print("  gitleaks also reported findings (run: gitleaks git --staged --redact)", file=sys.stderr)
        print("Remove the value (the line and rule are named; the value is not printed), then commit again.\n"
              "If the value is live, it also needs rotating: it has already been written to disk.", file=sys.stderr)
        return 1
    return 0


def _gitleaks(repo):
    from shutil import which
    if not which("gitleaks"):
        return 0
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as f:
        f.write(gitleaks_config())
        cfg = f.name
    try:
        new = subprocess.run(["gitleaks", "git", "--help"], capture_output=True).returncode == 0
        cmd = (["gitleaks", "git", "--pre-commit", "--staged", "--redact", "--no-banner", "--config", cfg, repo] if new
               else ["gitleaks", "protect", "--staged", "--redact", "--no-banner", "--config", cfg, "--source", repo])
        return subprocess.run(cmd, capture_output=True).returncode
    finally:
        os.unlink(cfg)


SHIM = """#!/bin/sh
# {marker} -- installed by secret-guard.py --install-precommit (agent-notepad session start).
# Do not edit: a repo-specific hook belongs in pre-commit.local, which this runs afterwards.
G="${{SECRET_GUARD_PATH:-{guard}}}"
if [ ! -f "$G" ]; then
  echo "secret-guard pre-commit: $G is missing, so nothing can check this commit for credentials." >&2
  echo "Reinstall the kit, or point SECRET_GUARD_PATH at secret-guard.py." >&2
  exit 1
fi
python3 "$G" --pre-commit || exit 1
L="$(dirname "$0")/pre-commit.local"
if [ -x "$L" ]; then exec "$L" "$@"; fi
exit 0
"""


def install_precommit(repo):
    r = _git(["rev-parse", "--git-path", "hooks"], repo)
    if r.returncode != 0:
        print(f"secret-guard: {repo} is not a git repository", file=sys.stderr)
        return 1
    hd = r.stdout.decode().strip()
    if not os.path.isabs(hd):
        hd = os.path.join(repo, hd)
    os.makedirs(hd, exist_ok=True)
    pc, local = os.path.join(hd, "pre-commit"), os.path.join(hd, "pre-commit.local")
    if os.path.exists(pc):
        with open(pc, errors="replace") as f:
            cur = f.read()
        if PRECOMMIT_MARKER not in cur and not os.path.exists(local):
            os.rename(pc, local)
        elif PRECOMMIT_MARKER not in cur:
            print(f"secret-guard: {pc} is someone else's hook and {local} already exists; not installing", file=sys.stderr)
            return 1
    body = SHIM.format(marker=PRECOMMIT_MARKER, guard=os.path.abspath(__file__))
    with open(pc, "w") as f:
        f.write(body)
    os.chmod(pc, 0o755)
    return 0


def gitleaks_config():
    out = ['# Generated by hooks/secret-guard.py --gitleaks-config. Do not edit: change RULES in that file.',
           'title = "secret-guard"', "", "[extend]", "useDefault = true", ""]
    for rid, rx, desc in RULES:
        out += ["[[rules]]", f'id = "{rid}"', f'description = "{desc}"', f"regex = '''{rx}'''", 'tags = ["secret-guard"]', ""]
    out += ["[[rules]]", 'id = "postgres-url-password"', 'description = "password inside a database or broker URL"',
            f"regex = '''{URL_PW_RE}'''", "secretGroup = 2", 'tags = ["secret-guard"]', ""]
    out += ["[allowlist]", 'description = "already-redacted text"', "regexes = ['''\\[REDACTED[^\\]]*\\]''']", ""]
    return "\n".join(out)


def filter_stream():
    r = Redactor()
    out = sys.stdout.buffer
    try:
        for raw in sys.stdin.buffer:
            s = raw.decode("utf-8", "surrogateescape")
            nl = s.endswith("\n")
            red = r.line(s[:-1] if nl else s)
            if red is None:
                continue
            out.write((red + ("\n" if nl else "")).encode("utf-8", "surrogateescape"))
            out.flush()
    except BrokenPipeError:
        # the reader went away (| head): stop quietly, as cat would
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    return 0


def main(argv):
    if argv[1:2] == ["--filter"]:
        return filter_stream()
    if argv[1:2] == ["--pre-commit"]:
        return pre_commit()
    if argv[1:2] == ["--install-precommit"]:
        return install_precommit(argv[2] if len(argv) > 2 else os.getcwd())
    if argv[1:2] == ["--gitleaks-config"]:
        print(gitleaks_config())
        return 0
    if os.environ.get("SECRET_GUARD", "on").lower() == "off":
        print("{}")
        return 0
    try:
        ev = json.load(sys.stdin)
    except ValueError:
        print("{}")
        return 0
    name = ev.get("hook_event_name", "")
    handler = {"PreToolUse": on_pre_tool_use, "PostToolUse": on_post_tool_use,
               "UserPromptSubmit": on_user_prompt}.get(name)
    print(json.dumps(handler(ev) if handler else {}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
