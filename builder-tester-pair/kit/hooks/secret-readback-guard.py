#!/usr/bin/env python3
"""PreToolUse guard — BLOCK Bash commands that would print secret material.

WHY: a transcript is persisted to disk, so a `grep` of a secret file "just to check the format" is a disclosure,
not a read. One careless read of a file already known to hold secrets is all it takes.

BLOCKS: reading a known secret-bearing path with a command that emits file CONTENT, unless the command masks or
measures instead; and `git remote -v` / `get-url` / `config --get remote.*.url`, which print URLs that often
embed a token. Extra project paths: guard.secret_paths in pair.yaml (regex fragments).

ALLOWS: length/presence checks (wc -c, ${#v}), masking (sed/re.sub), key-name-only extraction, writing without
reading (e.g. `az keyvault secret set --file`), and template files (.example/.sample/.template/.dist).

FAILS CLOSED: if a pair.yaml exists but cannot load, the project's secret paths are unknown, so every Bash command
is blocked until it loads (the Read/Edit tools stay free to fix it). No pair.yaml at all: the built-in paths only.

  python3 secret-readback-guard.py --selftest
"""
import json, os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib"))


def selftest():
    import subprocess, tempfile
    tmp = tempfile.mkdtemp(prefix="secret-guard-")
    good, broken = os.path.join(tmp, "pair.yaml"), os.path.join(tmp, "broken", "pair.yaml")
    os.makedirs(os.path.dirname(broken))
    with open(good, "w") as f:
        f.write("guard: {secret_paths: ['acme-creds\\.json']}\n")
    with open(broken, "w") as f:
        f.write("guard: [\n")
    v = "vault" + ".env"
    cases = [  # (want blocked, pair.yaml, command)
        (True, good, f"cat ~/{v}"),
        (True, good, f"grep TOKEN ~/{v}"),
        (False, good, f"wc -c ~/{v}"),
        (False, good, f"cat ~/{v}.example"),
        (True, good, "git remote -v"),
        (False, good, "git remote get-url origin | sed -E 's#//[^@]*@#//#'"),
        (True, good, "head -5 acme-creds.json"),            # guard.secret_paths from pair.yaml
        (False, good, "ls -la"),
        (False, good, f"cat > notes.md <<'EOF'\nnever cat {v}\nEOF"),
        (True, broken, "ls -la"),                           # pair.yaml present but broken: fail closed
        (True, os.path.join(tmp, "missing.yaml"), "ls -la"),    # PAIR_CONFIG names a missing file: fail closed too
    ]
    bad = 0
    for want, cfg, c in cases:
        r = subprocess.run([sys.executable, os.path.realpath(__file__)], input=json.dumps(
            {"tool_name": "Bash", "tool_input": {"command": c}}), text=True, capture_output=True,
            env=dict(os.environ, PAIR_CONFIG=cfg))
        got = r.returncode == 2 or '"deny"' in r.stdout
        bad += got != want
        print("PASS" if got == want else "FAIL", "block" if want else "allow", os.path.basename(os.path.dirname(cfg)) +
              "/" + os.path.basename(cfg), c.replace("\n", "⏎")[:60])
    print("ALL PASS" if not bad else f"{bad} FAILED")
    return 1 if bad else 0


if "--selftest" in sys.argv:
    sys.exit(selftest())

_EXTRA, _CFG_ERR = [], None
try:
    import pairconf
    _P = pairconf.find_config()
except BaseException:
    pairconf, _P = None, None
if _P is not None:             # found, named by PAIR_CONFIG, or a dangling home link: it must load
    try:
        _EXTRA = [x for x in (pairconf.get(pairconf.load(_P), "guard.secret_paths") or []) if x]
    except BaseException as _e:
        _CFG_ERR = f"{_P} cannot be loaded ({str(_e)[:160]})"

try:
    ev = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if ev.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (ev.get("tool_input") or {}).get("command", "") or ""
if _CFG_ERR:
    print(f"BLOCKED (secret-readback-guard): {_CFG_ERR}, so this project's secret paths are unknown. Shell commands "
          "are blocked until it loads: fix pair.yaml with the Read/Edit tools, then tell the owner.", file=sys.stderr)
    sys.exit(2)

# Paths whose CONTENT is secret material.
SECRET_PATHS = re.compile(
    r"secrets-local|"
    + "".join(x + "|" for x in _EXTRA) +       # project files (pair.yaml guard.secret_paths), NOT their .example
    r"vault\.env|"
    r"gh/hosts\.ya?ml|"
    r"\.docker(config)?json|"
    r"id_rsa|\.pem\b|\.kubeconfig",
    re.I,
)
# Commands that emit file content verbatim.

# --- GIT_CRED_URL -----------------------------------------------------------
# `git remote -v` / `git remote get-url` / `git config --get remote.*.url` print
# the remote VERBATIM, and many clones embed a token in the URL
# (https://x-access-token:<token>@github.com/...). Reading it is therefore a
# disclosure exactly like cat'ing a secret file -- but it is not a file read, so
# the path-based rules never see it.
#
# Allowed: anything that masks/strips the credential, or asks for a field that
# cannot contain one (e.g. `git remote` with no -v).
GIT_URL_RE = re.compile(
    r"\bgit\b[^|;&]*\b(?:remote\s+(?:-v|--verbose|get-url)|config\s+--get(?:-all)?\s+remote\.)",
    re.I)
MASKS = re.compile(r"\bsed\b|\bcut\b|\bawk\b|MASK|<REDACTED>|s@//[^@]*@", re.I)

# Template files carry placeholders by definition, never real values. Blocking
# `.example` / `.sample` / `.template` stopped a legitimate read of the very file
# that documents the required KEY NAMES -- which is the safe thing to consult
# instead of the real one. Only exempt when EVERY secret-ish path in the command
# is a template; a command touching both the real file and the template still denies.
EXAMPLE_RE = re.compile(r"\.(example|sample|template|dist)\b", re.I)

def only_templates(scan):
    found = False
    for m in re.finditer(r"[^\s'\"]*(?:secrets-local|" + "".join(x + "|" for x in _EXTRA) + r"vault\.env|hosts\.yml|dockerconfigjson|id_rsa|\.pem|kubeconfig)[^\s'\"]*", scan, re.I):
        found = True
        if not EXAMPLE_RE.search(m.group(0)):
            return False
    return found


def strip_heredocs(c: str) -> str:
    """Remove heredoc BODIES before pattern-matching.

    A command that WRITES documentation about a dangerous invocation is not that
    invocation. Both rules below match on command text, so a heredoc containing the
    words `git remote -v` (e.g. writing a memory file or a README that explains the
    rule) tripped the guard and blocked a harmless file write. Matching only the
    executable part fixes that without weakening either rule -- the body of a
    heredoc is data being written, never a command being run.
    """
    out, i = [], 0
    while True:
        j = c.find("<<", i)
        if j < 0:
            out.append(c[i:]); break
        out.append(c[i:j])
        k = j + 2
        if k < len(c) and c[k] == "-": k += 1
        q = ""
        while k < len(c) and c[k] in " \t": k += 1
        if k < len(c) and c[k] in "'\"": q = c[k]; k += 1
        s = k
        while k < len(c) and (c[k].isalnum() or c[k] == "_"): k += 1
        delim = c[s:k]
        if q and k < len(c) and c[k] == q: k += 1
        if not delim:
            out.append("<<"); i = j + 2; continue
        end = c.find("\n" + delim, k)
        i = (end + 1 + len(delim)) if end >= 0 else len(c)
    return "".join(out)


def check_git_url(cmd: str):
    if GIT_URL_RE.search(cmd) and not MASKS.search(cmd):
        return ("BLOCKED: `git remote -v` / `get-url` prints the remote URL verbatim, and "
                "clones often embed a token in it (https://x-access-token:<token>@github.com/...). "
                "That lands in the transcript, which persists to disk.\n\n"
                "Do one of these instead:\n"
                "  \u2022 host only:      git remote get-url origin | sed -E 's#//[^@]*@#//#'\n"
                "  \u2022 existence only: git remote            # names, no URLs\n"
                "  \u2022 is it https?:   git remote get-url origin | cut -d/ -f1")
    return None

EMITTERS = re.compile(r"\b(cat|bat|head|tail|less|more|strings|xxd|od|awk|cut|jq|yq)\b|"
                      r"\bgrep\b(?![^|;&]*\s-[A-Za-z]*[oclLq])|"
                      r"\bsed\b(?!.*s/)", re.I)

SAFE = re.compile(r"wc -c|wc -l|\$\{#|length\(|MASKED|<REDACTED>|"
                  r"re\.sub|sed -E? ?'s/|--file\b|shred|base64 -d \| wc", re.I)

_scan = strip_heredocs(cmd)
_git = check_git_url(_scan)
if _git:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": _git,
        }
    }))
    sys.exit(0)

if (SECRET_PATHS.search(_scan) and EMITTERS.search(_scan)
        and not SAFE.search(_scan) and not only_templates(_scan)):
    hit = SECRET_PATHS.search(_scan).group(0)
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"BLOCKED: this command reads secret material ({hit}) with a "
                f"content-emitting command. Output goes into the session transcript, "
                f"which is persisted to disk — that is a disclosure, not a read.\n\n"
                f"Do one of these instead:\n"
                f"  • measure, don't print:   len=$(...); echo ${{#len}}   |   wc -c\n"
                f"  • mask on the way out:    sed -E \"s/(password=)[^;]+/\\1<MASKED>/I\"\n"
                f"  • extract KEY NAMES only: grep -oP '^\\s+\\K[A-Za-z_]+(?=:)'\n"
                f"  • move value->vault without reading: az keyvault secret set --file <f>\n\n"
                f"If you genuinely must see a value, say so and get the operator's go first."
            ),
        }
    }))
    sys.exit(0)

sys.exit(0)
