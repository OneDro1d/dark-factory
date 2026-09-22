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
import shutil
import subprocess
import sys
import urllib.parse

MARKER = "# secret-guard: output is redacted"
WRAP_HEADER = f"{MARKER} (secret-guard.py); the original command follows unchanged\n"
PRECOMMIT_MARKER = "secret-guard pre-commit"

# ── the rule table: one source for the redactor, the prompt check, the pre-commit scan and the
# ── generated gitleaks config. Every regex is RE2-compatible (no look-around) so gitleaks,
# ── which is Go, can use it verbatim.
# ⚠️ Every prefix starts at a word boundary (\b). Without it `sk-` matched inside ordinary hyphenated
# words (disk-encryption-…, task-management-…): prompts were blocked, output was garbled, commits refused.
RULES = [
    ("synapse-pat", r"\bsyn_[A-Za-z0-9]{32,}", "Synapse personal access token"),
    ("github-token", r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})", "GitHub token"),
    ("slack-token", r"\bxox[abposr]-[A-Za-z0-9-]{10,}", "Slack token"),
    ("slack-app-token", r"\bxapp-[0-9]+-[A-Za-z0-9-]{10,}", "Slack app-level token"),
    ("stripe-live-key", r"\b(?:sk|rk)_live_[A-Za-z0-9]{16,}", "Stripe live key"),
    ("openai-key", r"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}", "OpenAI-style secret key"),
    ("supabase-secret-key", r"\bsb_secret_[A-Za-z0-9_-]{16,}", "Supabase secret key"),
    ("aws-access-key-id", r"\b(?:AKIA|ASIA)[0-9A-Z]{16}", "AWS access key id"),
    ("jwt", r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}", "JSON Web Token"),
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
# YAML / properties: `password: <value>`, which a Secret manifest and a values.yaml both use.
# Requires start-of-line (plus indent) so a prose colon mid-sentence is not a match.
_YAML_KV = re.compile(r"(?m)^(\s*-?\s*[\"']?)(" + _SECRET_KEY + r")([\"']?\s*:\s+)([^\s#][^\n#]{7,}?)(\s*)$", re.I)
# a value that is CODE, not a credential: a call, an index, a member access, a template hole.
_CODE_VALUE = re.compile(r"[A-Za-z_][A-Za-z0-9_.]*\s*\(|^\w+(\.\w+)+$|\$\{|\{\{|<%|os\.environ|process\.env")
# keys that end in "token" but hold pagination state, not credentials — masking them breaks paging
_NOT_SECRET_KEY = re.compile(r"page|cursor|continuation|next|count|type|usage|limit|max|input|output|total", re.I)

REDACTED = "[REDACTED]"


# ── the environment's own secrets ──────────────────────────────────────────────────────────────
_SECRET_NAME = re.compile(
    r"TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY|CREDENTIAL|(?:^|_)PAT(?:$|_)|(?:^|_)KEY$",
    re.I,
)
# ⚠️ a name that DESCRIBES a secret is not a secret. `SECRET_STORE_KIND=kubernetes` put the word
# "kubernetes" on the mask list, so it vanished from every command's output thereafter. The suffix
# is the tell: a KIND, a TYPE or a NAME names the thing, it is not the thing.
_NOT_SECRET_NAME = re.compile(
    r"^(?:SSH_AUTH_SOCK|GPG_AGENT_INFO|.*_KEY_ID|.*_KEYRING|.*_TOKEN_FILE|.*_KEY_FILE|.*_PATH"
    r"|.*_(?:KIND|TYPE|MODE|NAME|PROVIDER|BACKEND|SCHEME|FORMAT|ALGO|ALGORITHM|METHOD|SOURCE|STRATEGY|ENABLED|VERSION|URL|URI|HOST|ENDPOINT|REGION|TTL|EXPIRY|LENGTH|ROTATION))$",
    re.I)


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
        s = _YAML_KV.sub(lambda m: m.group(0) if _skip_kv(m.group(2), m.group(4))
                         else m.group(1) + m.group(2) + m.group(3) + REDACTED + m.group(5), s)
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
    # ⚠️ source code that MENTIONS a secret-named identifier is not a credential. Masking
    # `token = generateToken(user)` corrupts the file a reviewer is reading, and teaches the
    # reader that [REDACTED] means nothing in particular.
    if _CODE_VALUE.search(val.strip().strip("\"'")):
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
    "doctl-db": "This prints credentials (a database connection string or user password, a kubeconfig, or a registry auth). Put it straight where it is used without printing it, e.g. doctl kubernetes cluster kubeconfig save <cluster>, or pipe it into the consumer.",
    "doctl": "This prints the app spec, and DigitalOcean env values of type GENERAL are plain text in it. Names and types only: doctl apps spec get <id> | jq '[.. | .envs? // empty | .[] | {key, type}]'.",
    "gh-token": "This prints the GitHub token itself. To check a login: gh auth status (without -t). To use it, let gh send it (gh api ...) or rely on GH_TOKEN already in the environment; never print it.",
    "env": "This prints every environment variable's VALUE, tokens included. Names only: env | cut -d= -f1 . One variable set or not: test -n \"$NAME\" and echo the result.",
    "dotenv": "A .env file holds credential values. Names only: cut -d= -f1 <file> . A template without values (.env.example) is fine to read.",
    "proc-environ": "This prints a process's environment, tokens included. Names only: tr '\\0' '\\n' < /proc/<pid>/environ | cut -d= -f1 .",
    "vault": "This prints secret values. Read one field with -field=<key> and pipe it straight into its consumer (vault kv get -field=<key> <path> | kubectl create secret generic <name> --from-file=<key>=/dev/stdin), or check existence with vault kv metadata get <path>.",
    "az": "This prints the secret value. Names only: az keyvault secret list --vault-name <kv> --query '[].name' -o tsv .",
    "op": "This prints the secret to the terminal. Pipe it into its consumer, write it with --out-file, or use op run -- <cmd>, which injects secrets as env and masks them in output.",
    "aws": "This prints the secret value. Pipe it straight into its consumer, or list without values: aws secretsmanager list-secrets --query 'SecretList[].Name' --output text . For SSM, drop --with-decryption or read one parameter into the consumer.",
    "gcloud": "This prints the secret value. Pipe it straight into its consumer, or list without values: gcloud secrets list --format='value(name)' . Versions only: gcloud secrets versions list <secret>.",
    "helm": "A release's values carry whatever was passed in, passwords included. Names only: helm get values <release> -o json | jq 'paths(scalars) | join(\".\")' . The rendered manifest without values: helm get manifest <release>.",
    "git-credential": "This prints the stored password or token for a host. To check that a credential exists, use the helper's own listing (e.g. gh auth status, without -t); never fill it to a terminal.",
    "cred-file": "This file holds credentials in plain text. Read the part you need without the values: for ~/.aws/credentials use aws configure list-profiles; for ~/.kube/config use kubectl config get-contexts; for ~/.docker/config.json use jq '.auths | keys'; for ~/.netrc use cut -d' ' -f1,2.",
}
# a stage that merely PRINTS what it is given is not a consumer: piping into it still puts the
# value in the transcript, so `… | cat` must not buy an exemption that a bare command would not get.
PRINTERS = {"cat", "tee", "less", "more", "head", "tail", "bat", "batcat", "nl", "tac", "xxd",
            "od", "hexdump", "strings", "pr", "fold", "rev", "column", "view"}
READERS = {"cat", "less", "more", "head", "tail", "bat", "batcat", "nl", "tac", "strings", "xxd", "od",
           "hexdump", "grep", "egrep", "fgrep", "rg", "ag", "sed", "awk", "gawk", "sort", "uniq", "base64", "jq", "yq"}
WRAPPERS = {"sudo", "command", "exec", "time", "nohup", "nice", "stdbuf", "doas"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
DOTENV = re.compile(r"(?:^|/)(?:\.env(?:$|[.\-_][^/]*$)|\.envrc$)")
DOTENV_SAFE = re.compile(r"(?:example|sample|template|dist|defaults?|schema)$", re.I)
# ⚠️ `.env.ts` is TypeScript that READS the environment and `.env-guide.md` is documentation.
# Neither holds a value, and denying them is the kind of false positive that gets a guard
# switched off. A data extension (.env.json, .env.yaml) is NOT here: those do hold values.
DOTENV_SOURCE = re.compile(r"\.(?:ts|tsx|js|jsx|mjs|cjs|md|mdx|rst|txt|go|py|rb|rs|java|kt|php|c|h|cpp|sh|bash|zsh)$", re.I)
# files whose whole purpose is to hold credentials
CRED_FILE = re.compile(
    r"(?:^|/)(?:\.netrc|_netrc|\.pgpass|\.my\.cnf"
    r"|\.aws/credentials|\.docker/config\.json|\.kube/config"
    r"|\.config/gh/hosts\.yml|\.npmrc|\.pypirc)$")
STDOUTS = {"/dev/stdout", "/dev/fd/1", "-", "/proc/self/fd/1"}


def _is_stdout(p):
    return p in STDOUTS


def _dotenv_path(p):
    """True when p is a dotenv file that actually holds values."""
    return bool(DOTENV.search(p)) and not DOTENV_SAFE.search(p) and not DOTENV_SOURCE.search(p)


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
            # ⚠️ `cat < .env` reads the file WITHOUT naming it in argv. Dropping the target here
            # (what #209 did) made redirection a way to read any denied file. Keep it as a path.
            if t == "<" and i + 1 < len(toks):
                argv.append(toks[i + 1])
            i += 2
            continue
        elif not argv and t and t[0] in "({":
            # `(env)` lexes as ONE token, because parens are not punctuation to shlex. In COMMAND
            # position a paren or brace is grouping, never a name — but only there: awk's
            # '{print $1}' is an argument and must survive untouched, which is why this is
            # guarded on argv being empty.
            t = t.lstrip("({")
            while t and t[-1] in ")}":
                t = t[:-1]
            if t:
                argv.append(t)
            i += 1
            continue
        elif t in ("(", ")", "{", "}"):
            # grouping only: `(env)` and `{ env; }` run the same command. #209 parsed the paren
            # as the command name and saw nothing.
            i += 1
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
            # ⚠️ `timeout -s KILL 10 env`: #209 dropped only the flag, then read `-s` as the
            # command and stopped. Skip the options WITH their values, then the duration.
            rest = a[1:]
            while rest and rest[0].startswith("-"):
                if rest[0] in ("-s", "--signal", "-k", "--kill-after") and len(rest) > 1:
                    rest = rest[2:]
                elif "=" in rest[0] or rest[0] in ("--preserve-status", "--foreground", "-f"):
                    rest = rest[1:]
                else:
                    rest = rest[2:] if len(rest) > 1 else rest[1:]
            a = rest[1:] if rest else rest  # drop the duration
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
    # ⚠️ the field list must be EXACTLY 1. `-f1,2` and `-f1-3` keep the value as well, and #209's
    # `-f\s*1\b` matched both because \b sits happily before a comma.
    if argv[0] == "cut" and re.search(r"-d\s*=|-d\s*'='|--delimiter=?=", j) and re.search(r"-f\s*1(?![0-9,\-])|--fields=?1(?![0-9,\-])", j):
        return True
    # a stage that prints only a COUNT cannot leak a value: `printenv | wc -l`.
    if argv[0] == "wc" and argv[1:] and all(t in ("-l", "-w", "-c", "--lines", "--words", "--bytes") for t in argv[1:]):
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


# options that take a SEPARATE value: the value is not an operand, whatever it looks like.
# ⚠️ `kubectl get -n kube-system secret …` was ALLOWED by #209, because the first non-dash token
# is the namespace. Reading an option's value as the resource is how a deny list quietly stops
# denying — the command still names `secret`, one position further along.
_KUBECTL_VALUE_OPTS = {"-n", "--namespace", "-o", "--output", "-l", "--selector", "--field-selector",
                       "--context", "--kubeconfig", "--as", "--as-group", "--template", "--cluster",
                       "--user", "--server", "--token", "--chunk-size", "--sort-by"}
_SSH_VALUE_OPTS = {"-i", "-p", "-o", "-l", "-F", "-J", "-b", "-c", "-D", "-E", "-e", "-I", "-L",
                   "-m", "-O", "-Q", "-R", "-S", "-W", "-w"}


def _first_operand(argv, value_opts=_KUBECTL_VALUE_OPTS):
    """The first token that is a real operand, skipping options and the values they consume."""
    i = 0
    while i < len(argv):
        t = argv[i]
        if t == "--":
            i += 1
            continue
        if t.startswith("-"):
            i += 2 if (t in value_opts and "=" not in t) else 1
            continue
        return t
    return ""


def _operands(argv, value_opts):
    """Every operand, in order, with option values skipped."""
    out, i = [], 0
    while i < len(argv):
        t = argv[i]
        if t.startswith("-") and t != "--":
            i += 2 if (t in value_opts and "=" not in t) else 1
            continue
        if t != "--":
            out.append(t)
        i += 1
    return out


# a jsonpath / custom-columns template that touches only metadata prints NAMES, which is the
# safe form this guard recommends. Denying it is how people learn to switch the guard off.
def _template_is_names_only(tpl):
    """True when a jsonpath/custom-columns template never reaches secret material."""
    if ".data" in tpl or "data[" in tpl:
        return False
    refs = re.findall(r"\.[A-Za-z_][A-Za-z0-9_.]*", tpl)
    if not refs:
        return False
    return all(r.startswith((".metadata", ".items", ".kind", ".apiVersion", ".type")) for r in refs)


def _kubectl(argv):
    if "get" not in argv:
        if "create" in argv and "secret" in argv:
            fmt = _opt(argv, "-o", "--output") or ""
            return "kubectl" if fmt.split("=")[0] in ("yaml", "json") else None
        return None
    rest = argv[argv.index("get") + 1:]
    res = _first_operand(rest)
    # ⚠️ `secrets.v1.` is the same resource: kubectl accepts <resource>.<version>.<group>.
    kinds = {r.split("/")[0].split(".")[0].lower() for r in res.split(",")}
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
    if kind in ("jsonpath", "jsonpath-as-json", "custom-columns", "custom-columns-file") and "=" in fmt:
        if _template_is_names_only(fmt.split("=", 1)[1]):
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
        # ⚠️ option VALUES are not the host: `ssh -i key host env` gave #209 the operand list
        # ["key","host","env"], so it read the remote command as "host env" and found nothing.
        cmdargs = _operands(a[1:], _SSH_VALUE_OPTS)[1:]
        return deny_reason(shlex.join(cmdargs), nested=True) if cmdargs else None
    if c in ("kubectl", "k", "oc", "kubectl.exe"):
        if "exec" in a:
            # `--` is conventional, not required: `kubectl exec pod env` runs env just the same.
            if "--" in a:
                rest = a[a.index("--") + 1:]
            else:
                rest = _operands(a[a.index("exec") + 1:], _KUBECTL_VALUE_OPTS)[1:]
            return deny_reason(shlex.join(rest), nested=True) if rest else None
        return _kubectl(a)
    if c in ("docker", "podman", "nerdctl") and "exec" in a:
        rest = _operands(a[a.index("exec") + 1:], {"-e", "--env", "-u", "--user", "-w", "--workdir"})[1:]
        return deny_reason(shlex.join(rest), nested=True) if rest else None
    if c == "ps":
        # `ps eww` prints each process's ENVIRONMENT — but ONLY in BSD syntax, where flags carry
        # no dash. In UNIX syntax `-e` means "every process" and prints no environment at all, so
        # `ps -ef` is the most ordinary invocation there is and must stay allowed.
        val_opts = {"-o", "-O", "--format", "-p", "--pid", "--ppid", "-u", "-U", "--user",
                    "-g", "-G", "--group", "-s", "--sid", "-t", "--tty", "-C", "--sort"}
        skip = False
        for t in a[1:]:
            if skip:
                skip = False
                continue
            if t in val_opts:
                skip = True
                continue
            # a BSD flag cluster: letters only, no dash. `-o pid,etime` is a VALUE, not flags.
            if not t.startswith("-") and re.fullmatch(r"[a-zA-Z]+", t) and "e" in t:
                return "proc-environ"
        return None
    if c == "aws":
        sub = _operands(a[1:], {"--region", "--profile", "--output", "--secret-id", "--query"})
        if sub[:2] == ["secretsmanager", "get-secret-value"] or sub[:2] == ["ssm", "get-parameter"] \
           or sub[:2] == ["ssm", "get-parameters"] or sub[:2] == ["ssm", "get-parameters-by-path"]:
            return "aws"
        return None
    if c == "gcloud":
        sub = _operands(a[1:], {"--secret", "--project", "--format"})
        if sub[:3] == ["secrets", "versions", "access"]:
            return "gcloud"
        return None
    if c == "helm":
        sub = _operands(a[1:], {"-n", "--namespace", "--kubeconfig", "-o", "--output"})
        if sub[:2] == ["get", "values"] or sub[:2] == ["get", "all"]:
            return "helm"
        return None
    if c == "git" and a[1:3] == ["credential", "fill"]:
        return "git-credential"
    if c == "gh":
        if a[1:3] == ["auth", "token"]:
            return "gh-token"
        if a[1:3] == ["auth", "status"] and ({"-t", "--show-token"} & set(a)):
            return "gh-token"
        return None
    if c == "printenv":
        # ⚠️ `printenv NAME` prints ONE variable. Denying `printenv HOME` and `printenv PATH`
        # teaches people that the guard is noise, and a guard people route around protects
        # nothing. A secret-NAMED variable is still denied — that is D6c/H1a2.
        names = [t for t in a[1:] if not t.startswith("-")]
        if names:
            return "env" if any(_SECRET_NAME.search(n) and not _NOT_SECRET_NAME.match(n) for n in names) else None
        return "env"
    if c in ("set", "export", "declare", "typeset") and (len(a) == 1 or a[1:] in (["-p"], ["-x"], ["-px"], ["-xp"])):
        return "env" if c != "set" or len(a) == 1 else None
    if c == "doctl":
        # Only the subcommands that print secret material. `-o json` on anything else (droplet list,
        # cluster list) prints nothing a text listing would not, so it is allowed.
        sub = [t for t in a[1:] if not t.startswith("-")]
        fmt = (_opt(a, "-o", "--output") or "").lower()
        if sub[:1] == ["apps"]:
            if sub[1:2] == ["get"] or fmt.startswith("json"):
                return "doctl"
            if sub[1:3] == ["spec", "get"] and not piped and not redirected:
                return "doctl"
        if sub[:1] == ["databases"] and (sub[1:2] == ["connection"] or
                                         (sub[1:2] in (["user"], ["pool"]) and sub[2:3] in (["get"], ["list"], ["reset"]))):
            return "doctl-db"
        if sub[:4] == ["kubernetes", "cluster", "kubeconfig", "show"] or sub[:2] == ["registry", "docker-config"]:
            return "doctl-db"
        return None
    if c == "vault":
        if a[1:3] == ["kv", "get"] or a[1:2] == ["read"]:
            if not any(t == "-field" or t.startswith("-field=") for t in a):
                return "vault"
            return None if (piped or redirected) else "vault"
        return None
    if c == "az" and a[1:3] == ["keyvault", "secret"]:
        if a[3:4] == ["show"]:
            return "az"
        # `--file /dev/stdout` turns a download into a print.
        if a[3:4] == ["download"] and _is_stdout(_opt(a, "-f", "--file") or ""):
            return "az"
        return None
    if c == "op":
        if a[1:2] == ["read"] and not (piped or redirected or "--out-file" in a or "-o" in a):
            return "op"
        if a[1:3] == ["item", "get"] and "--reveal" in a:
            return "op"
        return None
    if c in ("cp", "install", "mv") and len(a) >= 3:
        # `cp .env /dev/stdout` is a read dressed as a copy.
        src, dst = a[1:-1], a[-1]
        if _is_stdout(dst) and any(_dotenv_path(p) or CRED_FILE.search(p) for p in src if not p.startswith("-")):
            return "dotenv"
        return None
    if c in READERS:
        paths = [t for t in a[1:] if not t.startswith("-")]
        if any("/proc/" in p and p.endswith("/environ") for p in paths):
            return "proc-environ"
        if c in ("grep", "egrep", "fgrep", "rg") and re.search(r"(?:^|\s)-[a-zA-Z]*[clLq]", joined):
            return None
        if any(_dotenv_path(p) for p in paths):
            return "dotenv"
        if any(CRED_FILE.search(p) for p in paths):
            return "cred-file"
    return None


def deny_reason(cmd, nested=False):
    """The deny-rule key for a whole command line, or None."""
    try:
        pipelines = _structure(cmd)
    except ValueError:
        return _raw_fallback(cmd)
    for stages in pipelines:
        for idx, (argv, redir) in enumerate(stages):
            rest = stages[idx + 1:]
            nxt = rest[0] if rest else None
            # ⚠️ `doctl apps spec get … | cat` is not "piped into a consumer", it is printed.
            # #209 treated ANY pipe as a consumer, so appending `| cat` lifted the deny.
            consumed = bool(rest) and not all(
                (s[0] and os.path.basename(_strip_prefix(s[0])[0][0] if _strip_prefix(s[0])[0] else s[0][0]) in PRINTERS)
                for s in rest)
            key = _rule_for(argv, piped=consumed, redirected=redir)
            if key in ("env",) and nxt is not None and _names_only(nxt):
                continue
            if key == "kubectl" and nxt is not None and _keys_only(nxt):
                continue
            if key:
                return key
    return None


def _keys_only(stage):
    """True when the next stage keeps only the KEY names of a JSON object (`jq '.data|keys'`)."""
    argv = stage[0]
    if not argv or os.path.basename(argv[0]) not in ("jq", "yq"):
        return False
    prog = " ".join(t for t in argv[1:] if not t.startswith("-"))
    return bool(re.search(r"\|\s*keys(_unsorted)?\b", prog)) and ".data." not in prog and "values" not in prog


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
    Portable to bash 3.2 and zsh (no process substitution, no `wait` on one).

    ⛔ THE COMMAND RUNS IN A SUBSHELL whose stdout+stderr go to the capture file, and nothing else
    is open for it. The first version redirected the session shell itself (`exec >file`, with the
    real outputs saved on fds 3/4 and an EXIT trap). Everything the command could do to that shell
    broke it: `export PATH=…` hid python3 from the tail, `exec` or its own `trap … EXIT` skipped
    the tail and left the capture file unredacted, `>&3` wrote past the filter, a function named
    python3 replaced the filter, and a trailing `\\` glued the tail onto the command. In a
    subshell none of that reaches the tail. The tail uses absolute paths anyway, and the fds a
    parent might have left open (3-9) are closed for the command. The blank line after the command
    absorbs a trailing `\\`. The subshell writes its final cwd to a side file and the tail cds
    there, so a cd in the command still moves the session. After an `exit` inside the command the
    cwd is not carried, just as Claude Code does not record it when the shell exits.
    """
    g = shlex.quote(os.path.abspath(__file__))
    py = shlex.quote(sys.executable or "python3")
    rm = shlex.quote(shutil.which("rm") or "/bin/rm")
    mk = shlex.quote(shutil.which("mktemp") or "/usr/bin/mktemp")
    return (
        WRAP_HEADER
        + f'__sg_f="$({mk} "${{TMPDIR:-/tmp}}/secret-guard.XXXXXX")"\n'
        + "(\n"
        + f"{cmd}\n"
        + "\n"
        + '__sg_rc=$?; pwd -P >"$__sg_f.cwd" 2>/dev/null; exit $__sg_rc\n'
        + ') >"$__sg_f" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-\n'
        + f'__sg_rc=$?; {py} {g} --filter <"$__sg_f"; {rm} -f "$__sg_f"\n'
        + f'if [ -s "$__sg_f.cwd" ]; then IFS= read -r __sg_c <"$__sg_f.cwd"; builtin cd "$__sg_c" 2>/dev/null; fi; {rm} -f "$__sg_f.cwd"\n'
        + "(exit $__sg_rc)"
    )


def _unwrap(cmd):
    """The original command if cmd is EXACTLY what _wrap generated for it, else None.

    ⛔ Never "contains the marker": a comment carrying the marker text used to skip the whole hook,
    deny list included. And never "starts with the header" alone: a forged header followed by
    anything would skip the redaction. Only a byte-exact regeneration counts as already wrapped.
    """
    if not cmd.startswith(WRAP_HEADER):
        return None
    lines = cmd.split("\n")
    # header, mktemp, "(", <cmd lines…>, "", rc line, ")" redirect, tail x2, "(exit …)"
    if len(lines) < 10 or lines[2] != "(":
        return None
    inner = "\n".join(lines[3:-6])
    return inner if _wrap(inner) == cmd else None


# ── hook entry points ────────────────────────────────────────────────────────────────────────────
def on_pre_tool_use(ev):
    if ev.get("tool_name") != "Bash":
        return {}
    ti = ev.get("tool_input") or {}
    cmd = ti.get("command") or ""
    if not isinstance(cmd, str) or not cmd.strip():
        return {}
    # The deny list runs FIRST, on the command as given: nothing in the text can switch it off.
    key = deny_reason(cmd)
    if key:
        reason = "secret-guard: denied. " + MSG[key]
        return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                       "permissionDecisionReason": reason}}
    if _unwrap(cmd) is not None:
        return {}  # this hook's own wrapper, byte for byte: do not wrap it twice
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
    # ⛔ core.hooksPath (set at ANY scope) means the hooks directory is someone else's: a global
    # one is shared by every repo on the machine, and a repo one is usually a hook manager's
    # (husky's .husky/_). Installing there renamed their pre-commit. Skip, and say so.
    hp = _git(["config", "--get", "core.hooksPath"], repo)
    if hp.returncode == 0 and hp.stdout.strip():
        print(f"secret-guard: {repo} uses core.hooksPath={hp.stdout.decode().strip()}; that directory is not ours, "
              "so the credential pre-commit was NOT installed. Call `secret-guard.py --pre-commit` from that hook to add it.",
              file=sys.stderr)
        return 0
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
    try:
        name = ev.get("hook_event_name", "")
        handler = {"PreToolUse": on_pre_tool_use, "PostToolUse": on_post_tool_use,
                   "UserPromptSubmit": on_user_prompt}.get(name)
        out = handler(ev) if handler else {}
    except Exception as e:  # malformed input must not crash the hook; say what happened, change nothing
        print(f"secret-guard: ignored an event it could not read ({type(e).__name__})", file=sys.stderr)
        out = {}
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
