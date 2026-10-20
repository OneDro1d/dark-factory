#!/usr/bin/env python3
"""PreToolUse(Bash) — deployments are the owner's. The builder and tester prepare; the owner deploys, or
opens a time-boxed approval window the builder may deploy inside.

STATUS: a TRIPWIRE, not the boundary. The boundary should be a read-only kubeconfig for the agents: with it,
any cluster write fails 403 however it is spelled. This hook catches the ordinary ways an agent would write
anyway, hands the exact command to the owner, and records it on the ledger as NEEDS OWNER. A same-identity
regex can never be complete — every bypass found in review is a self-test case below.

BLOCKS: kubectl/oc/k/helm writes (incl. run, debug, cp, exec, uncordon, certificate, set *),
`--dry-run=none`, raw API calls to the apiserver or with the SA token, `az aks` changes,
terraform apply/destroy, `gh workflow run`, `make *deploy*|*rollout*`, piping anything into a shell,
and SCRIPTS whose CONTENT contains any of the above (the script file is read and judged, so names
do not matter). Scripts listed in guard.safe_script_subs (pair.yaml) are judged by subcommand instead.
ALLOWS: reads, `--dry-run=client|server`, helm get/diff/template/list/status/show/--dry-run,
image builds and registry pushes, git, and text that merely mentions a command.
HUMAN PATH: the owner runs the handed-over command themselves with `!` (hooks do not gate them).
"""
import json, os, re, sys
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
try:
    import ledger_common as L
except Exception:            # never fail open because the shared module is missing
    L = None
# The event is read first: the fail-closed branch below needs to know which tool this is.
_EV = None
if "--selftest" not in sys.argv:
    try:
        _EV = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if not isinstance(_EV, dict) or _EV.get("tool_name") != "Bash":
        sys.exit(0)            # this gate judges shell commands only (reads/edits are pair-guard's)
try:
    import pairconf
    _PATH = pairconf.find_config()
except BaseException:          # kit not installed on this machine
    _PATH = None
if _PATH is None:              # no pair.yaml anywhere: this machine is not one of a pair's workspaces
    pairconf, CFG = None, None
else:
    try:
        CFG = pairconf.load(_PATH)
    except BaseException as _e:  # pair.yaml exists but cannot be read: FAIL CLOSED, never switch the guard off
        # Only Bash reaches here (see above), so the Read/Edit tools stay free to fix pair.yaml.
        print(f"BLOCKED (deploy-gate): {_PATH} cannot be loaded ({str(_e)[:200]}). Shell commands are blocked until it "
              "loads: fix pair.yaml with the Read/Edit tools, then the owner runs `./setup-pair check`. Tell the owner.",
              file=sys.stderr)
        sys.exit(2)
_G = (lambda k, d=None: pairconf.get(CFG, k, d)) if CFG else (lambda k, d=None: d)
OWNER = str(_G("owner.short_name") or (_G("owner.name") or "the owner").split()[0])
# the owner's approval tool lives in the KIT's bin, also when this hook runs as an installed copy in ~/.claude/hooks
APPROVE_CMD = os.path.join(str(getattr(pairconf, "KIT_ROOT", "") or os.path.join(HERE, "..", "..")) if pairconf else
                           os.path.join(HERE, "..", ".."), "kit", "bin", "approve-" + "deploy")

KTOOL = r"(?:kubectl|oc|k)"
WRITE_SUB = {"apply", "create", "replace", "patch", "edit", "delete", "scale", "autoscale", "expose",
             "label", "annotate", "cordon", "uncordon", "drain", "taint", "run", "debug", "cp", "exec",
             "attach", "certificate", "set", "rollout", "proxy"}
READ_ROLLOUT = {"status", "history"}
VALUE_FLAGS = {"-n", "--namespace", "--context", "--kubeconfig", "-l", "--selector", "-o", "--output",
               "-c", "--container", "--cluster", "--user", "-s", "--server", "--request-timeout",
               "--as", "--as-group", "--as-uid", "--token", "--field-selector"}
HELM_READ = {"get", "diff", "template", "list", "ls", "status", "show", "history", "search", "repo",
             "version", "lint", "dependency", "env", "help"}
# {script basename: [subcommands that are NOT deploys]} — e.g. a checker CLI whose only deploying verb is onboard.
# the kit's own runner script: every subcommand is read-only or the tester's own, except `onboard` (a cluster write)
ARGUS_SAFE = {"setup", "login", "doctor", "validate", "seed", "run", "status", "schedule", ""}
SAFE_SCRIPT_SUBS = {"argus.sh": set(ARGUS_SAFE),
                    **{k: set(v or []) for k, v in (_G("guard.safe_script_subs") or {}).items()}}
OTHER = [
    r"kubernetes\.default\.svc|/var/run/secrets/kubernetes\.io/serviceaccount/token|\.azmk8s\.io",
    r"\baz\s+aks\b[^|;&\n]*\b(nodepool|scale|update|upgrade|create|delete|stop|start|command\s+invoke|rotate-certs|enable-addons|disable-addons)\b",
    r"\bterraform\b[^|;&\n]*\b(apply|destroy|import|state\s+rm)\b",
    r"\bgh\s+workflow\s+run\b|\bgh\s+api\b[^|;&\n]*actions/workflows/[^|;&\n]*dispatches",
    # make/gmake as a word (also /usr/bin/make, "make"), not the `make` inside a file name like make-agent-x.sh
    r"(?<![\w.-])g?make(?![\w.-])[\"']?[^|;&\n]*\b[\w-]*(deploy|rollout|release|install|apply)[\w-]*\b",
    r"\beval\b",                      # any spelling: 'eval', "eval", x=eval; $x — eval runs text this gate never sees
]
# Judged per pipe segment of a step; a segment that only prints or searches text (no $(…), backticks or `eval`)
# is skipped: text that merely MENTIONS a command is not that command.
TEXT_ONLY = re.compile(r"^\s*(echo|printf|grep|egrep|fgrep|rg|#)\b")
# A shell program, also behind wrappers (env, sudo -E, xargs -0, busybox, exec, nohup…) and quotes, or $SHELL.
_WRAP = r"(?:(?:\S*/)?(?:sudo|env|exec|nohup|command|builtin|time|nice|stdbuf|busybox|xargs|doas)\b(?:\s+-\S+)*\s+(?:[A-Za-z_]\w*=\S*\s+)*)*"
_SH = r"(?:[\"']?(?:\S*/)?(?:ba|z|da|k|c|tc|fi|mk|y)?sh[\"']?(?![\w.-])|\$\{?SHELL\}?)"
SHELL_CMD = re.compile(r"^\s*" + _WRAP + _SH + r"(?!\s+-n\b)")
SHELL_ANY = re.compile(r"(?:^|[\s;&|(`])" + _WRAP + _SH)
# Code run by an interpreter that executes text it reads at run time: perl -e 'system(`cat x`)', python -c "…open…"
INTERP_EXEC = re.compile(r"\b(perl|python3?|node|ruby|php)\b[^|&\n]*\s-[ec]\b[^|&\n]*"
                         r"(system|exec|popen|subprocess|spawn|child_process)[^|&\n]*(`|\bcat\b|open\s*\(|read|\$\()")


def normalise(cmd):
    c = re.sub(r"\\\n", " ", cmd)                                  # line continuation
    c = re.sub(r"''|\"\"", "", c)                                    # kub''ectl
    c = re.sub(r"\\(?=[A-Za-z])", "", c)                             # kube\ctl
    for var, val in re.findall(r"\b([A-Za-z_]\w*)=['\"]?(kubectl|oc|helm|k)['\"]?(?=\s|;|$)", c):
        c = re.sub(r"\$\{?" + var + r"\}?", val, c)                  # KC=kubectl; $KC apply
    c = re.sub(r"\$\(\s*(?:which|command\s+-v)\s+(kubectl|helm|oc)\s*\)", r"\1", c)
    return c


def strip_commit_text(c):
    if re.search(r"\bgit\s+(commit|tag)\b", c):
        c = re.sub(r"(-m|--message)\s+(\"[^\"]*\"|'[^']*')", "", c)
        c = re.sub(r"(\bgit\s+(?:commit|tag)\b[^\n]*<<-?\s*'?(\w+)'?\n).*?\n\2\b", r"\1<<MSG", c, flags=re.S)
    return c


def heredoc_split(c):
    """Return (outer command, [(interpreter, body)]). Bodies of `python3 - <<EOF` are code, not shell."""
    bodies = []
    def keep(m):
        bodies.append((m.group(1) or "", m.group(3)))
        return m.group(0).split("\n", 1)[0] + "\n<<BODY>>"
    c2 = re.sub(r"(?m)^(.*?)<<-?\s*['\"]?(\w+)['\"]?[^\n]*\n(.*?)\n\2\s*$", keep, c, flags=re.S)
    return c2, bodies


def ksub(seg):
    seg = re.sub(r"\s#.*$", "", seg)                                 # a trailing comment is not a flag
    seg = re.sub(r"\$\(|`|\)|[\"']", " ", seg)                       # $(kubectl …), `kubectl …`, "…" wrappers
    toks = seg.split()
    for i, t in enumerate(toks):
        if re.fullmatch(KTOOL, os.path.basename(t)):
            j = i + 1
            while j < len(toks):
                x = toks[j]
                if x in VALUE_FLAGS:
                    j += 2; continue
                if x.startswith("-"):
                    j += 1; continue
                nxt = toks[j + 1] if j + 1 < len(toks) else ""
                return x, nxt
            return None, ""
    return None, ""


def k_write(seg):
    seg = re.sub(r"\s#.*$", "", seg)
    if not re.search(r"(^|[\s/;(|&`\"'])" + KTOOL + r"\s", " " + seg):
        return False
    sub, nxt = ksub(seg)
    if sub is None:
        return False
    if sub == "rollout" and nxt in READ_ROLLOUT:
        return False
    if sub == "auth" or sub not in WRITE_SUB:
        return False
    dr = re.search(r"--dry-run(?:=(\w+))?", seg)
    if dr and (dr.group(1) or "client") in ("client", "server"):
        return False
    return True


def helm_write(seg):
    m = re.search(r"(^|[\s/;(|&`])helm\s+(\S+)", " " + seg)
    if not m:
        return False
    sub = m.group(2)
    if sub in HELM_READ or "--dry-run" in seg:
        return False
    return sub in {"install", "upgrade", "uninstall", "delete", "rollback", "del", "un"}


def script_runs(seg):
    """Scripts this segment EXECUTES (not edits/greps/logs): `bash|sh|source|. <file>` (any name, not only *.sh),
    `sh < file`, and ./x.sh or /path/x.sh run directly."""
    out = []
    if re.search(r"\b(?:ba|z|da|k)?sh\s+-n\b", seg):
        return out                                     # syntax check only
    # `bash [flags] FILE` (not `bash -c 'text'`, judged separately), and `source FILE` / `. FILE` at command position
    for m in re.finditer(r"(?:^|[\s;&|(])" + _WRAP + r"[\"']?(?:\S*/)?(?:ba|z|da|k)?sh[\"']?"
                         r"((?:\s+-[a-zA-Z]+)*)\s+(?!-)([^\s<>|;&()]+)(\s+\S+)?", " " + seg):
        if "c" not in m.group(1).replace("-", ""):
            out.append((m.group(2), (m.group(3) or "").strip()))
    for m in re.finditer(r"(?:^|[;&|(])\s*(?:source|\.)\s+(?!-)([^\s<>|;&()]+)(\s+\S+)?", seg):
        out.append((m.group(1), (m.group(2) or "").strip()))
    for m in re.finditer(r"(?:^|[\s;&|(])" + _WRAP + r"(?:\S*/)?(?:ba|z|da|k)?sh\s*<\s*([^\s<>|;&()]+)", " " + seg):
        out.append((m.group(1), ""))
    for m in re.finditer(r"(?:^|[\s;&|(])(\.?/[\w./~$-]+\.sh)\b(\s+\S+)?", " " + seg):
        out.append((m.group(1), (m.group(2) or "").strip()))
    return out


def _cd_steps(c):
    """How many `cd` this gate can follow: a whole step that is exactly `cd <dir>` (no `..`, no `-`, no $/`).
    Any other cd/pushd/popd (subshell, `cd --`, `cd x 2>/dev/null`, `builtin cd`, `cd ..`) makes the working
    directory unknown, and then a relative script path fails closed."""
    total = len(re.findall(r"(?<![\w.-])(?:cd|pushd|popd|chdir)(?![\w.-])", c))
    followed = [m.group(1) for m in (re.fullmatch(r"\s*cd\s+([^\s$`;&|<>()-][^\s$`;&|<>()]*)\s*", s)
                                     for s in re.split(r";|&&|\|\||\n", c)) if m and ".." not in m.group(1).split("/")]
    return total, followed


def is_deploy(cmd, depth=0, cwd=None):
    """True if the command (or a script/heredoc it runs) writes to a cluster. `cwd` is where the command runs (the
    hook event's cwd); a `cd <dir>` step moves it for the steps after it, so relative script paths resolve right."""
    cwd = cwd or os.getcwd()
    c = strip_commit_text(normalise(cmd))
    c, bodies = heredoc_split(c)
    for interp, body in bodies:          # shell heredocs are commands; python ones only via subprocess/os
        if re.search(r"\b(bash|sh|zsh)\b", interp) and is_deploy(body, depth + 1):
            return True
        if re.search(r"python|node|perl|ruby", interp) and re.search(r"subprocess|os\.system|popen|execSync|child_process", body) \
                and re.search(r"kube|helm|kubernetes\.default", body):
            return True
    if re.search(r"subprocess|os\.system|popen", c) and re.search(r"kube|helm", c) and re.search(r"python|node|perl", c):
        return True
    if INTERP_EXEC.search(c):
        return True                       # perl -e 'system(`cat x`)': runs text read at run time
    total_cd, followed = _cd_steps(c)
    cwd_known = total_cd == len(followed)
    written = set()                       # files this command writes before it may run them (cat x > r.sh; bash r.sh)
    for step in re.split(r";|&&|\|\||\n", c):
        cd = re.fullmatch(r"\s*cd\s+(\S+)\s*", step)
        if cd and cwd_known:
            # bash's `cd` is LOGICAL (cd lnk/.. stays put): normpath, not a physical join
            cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(cd.group(1).strip("'\""))))
            continue
        segs = re.split(r"\|&?(?!\|)", step)
        for i, seg in enumerate(segs):
            if i > 0 and SHELL_CMD.match(seg):
                return True               # … | sh, … | env bash, … | xargs sh -c: what reaches the shell is unseen
            if TEXT_ONLY.match(seg) and not re.search(r"\$\(|`", seg):
                continue                  # text that merely mentions a command
            if any(re.search(p, seg) for p in OTHER):
                return True
            if k_write(seg) or helm_write(seg):
                return True
            # a shell fed text this gate cannot read: -c "$(…)", <(…), /dev/stdin, <<< "$(…)"
            if SHELL_ANY.search(seg) or re.search(r"(?:^|[;&|(])\s*(?:source|\.)\s", seg):
                mc = re.search(r"\s-[a-zA-Z]*c[a-zA-Z]*\s+(['\"])(.*?)\1", seg)
                if mc and (re.search(r"\$\(|`|<\(", mc.group(2)) or is_deploy(mc.group(2), depth + 1, cwd)):
                    return True
                if mc is None and re.search(r"\s-[a-zA-Z]*c[a-zA-Z]*\s+[\"']?\$", seg):
                    return True           # bash -c $VAR
                if re.search(r"<\(|/dev/stdin|/proc/self/fd|<<<", seg):
                    return True
            for t in re.findall(r"(?:>>?|\btee\s+(?:-a\s+)?|\b(?:cp|mv|install|dd\b[^|;&]*\bof=)\s*(?:\S+\s+)*?)\s*([^\s<>|;&()]+)", seg):
                written.add(os.path.normpath(os.path.join(cwd, os.path.expanduser(t))))
            for path, arg in script_runs(seg):
                name = os.path.basename(path)
                if name in SAFE_SCRIPT_SUBS:
                    if arg not in SAFE_SCRIPT_SUBS[name]:
                        return True
                    continue
                path = os.path.expanduser(path)
                if not os.path.isabs(path) and not cwd_known:
                    return True           # cannot tell which file a relative path names here (fail closed)
                if "$" in path or "`" in path:
                    return True           # the shell's variables are not this process's
                p = os.path.normpath(os.path.join(cwd, path))
                if p in written:
                    return True           # rewritten earlier in this same command: the file on disk is not what runs
                if depth < 2:
                    try:
                        if os.path.getsize(p) <= 512_000:
                            with open(p, errors="replace") as fh:
                                if is_deploy(fh.read(), depth + 1, cwd=cwd):   # a script runs in the CALLER's cwd
                                    return True
                    except OSError:
                        return True       # cannot see the script = cannot vouch for it (fail closed)
    return False


if "--selftest" in sys.argv:
    import tempfile
    t = tempfile.mkdtemp()
    SAFE_SCRIPT_SUBS["checker.sh"] = {"setup", "doctor", "validate", "run", "status", ""}
    with open(f"{t}/ship-overlay.sh", "w") as f:
        f.write("#!/bin/bash\nkubectl -n \"$1\" apply -k overlays/dev\n")
    with open(f"{t}/report.sh", "w") as f:
        f.write("#!/bin/bash\nkubectl get pods -A | wc -l\n")
    # sub/report.sh DEPLOYS; sub/lnk -> real/inner, and real/report.sh is harmless: `cd sub/lnk && cd ..` is sub in bash
    os.makedirs(f"{t}/sub"); os.makedirs(f"{t}/real/inner")
    with open(f"{t}/sub/report.sh", "w") as f:
        f.write("#!/bin/bash\nkubectl apply -f x.yaml\n")
    with open(f"{t}/real/report.sh", "w") as f:
        f.write("#!/bin/bash\nkubectl get pods\n")
    os.symlink(f"{t}/real/inner", f"{t}/sub/lnk")
    with open(f"{t}/cmd.txt", "w") as f:
        f.write("kubectl apply -f x.yaml\n")
    pod_tok = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    cases = [
        # v1 self-test
        (True, "kubectl -n pay-midtier set image deploy/a a=b"),
        (True, "kubectl apply -k overlays/dev-midtier"),
        (True, "kubectl --context dev-cluster create -f out/x.yaml"),
        (True, "kustomize build overlays/dev | kubectl apply -f -"),
        (True, "kubectl -n pay-backtier rollout restart deploy/api"),
        (True, "kubectl delete job e2e -n pay-midtier"),
        (True, "helm upgrade --install x chart -n pay-midtier"),
        (True, "kubectl scale deploy/a --replicas=0 -n x"),
        (True, "bash ./checker.sh onboard api ns ws img@sha256:x"),
        # v2 — the 30 bypasses from the review
        (True, "KC=kubectl; $KC apply -f x.yaml"),
        (True, "H=helm; $H upgrade x chart"),
        (True, "kubectl -n pay-midtier \\\n  apply -f x.yaml"),
        (True, "kubectl apply --dry-run=none -f x.yaml"),
        (True, "kubectl apply -f x.yaml  # not --dry-run"),
        (True, "echo $(kubectl apply -f x.yaml)"),
        (True, "printf '%s' \"$(kubectl delete pod x)\""),
        (True, "kube\\ctl apply -f x.yaml"),
        (True, "kub''ectl apply -f x.yaml"),
        (True, "echo a3ViZWN0bCBhcHBseSAtZiB4LnlhbWwK | base64 -d | bash"),
        (True, "python3 -c 'import subprocess as s; s.run([\"kube\"+\"ctl\",\"app\"+\"ly\",\"-f\",\"x\"])'"),
        (True, f"bash {t}/ship-overlay.sh pay-midtier"),
        (True, f"bash {t}/ship-overlay.sh pay-midtier # tail"),
        (True, f"cat {t}/ship-overlay.sh | bash -s pay-midtier"),
        (True, "make deploy"),
        (True, "oc apply -f x.yaml"),
        (True, "k apply -f x.yaml"),
        (True, f"curl -sk -X PATCH -H \"Authorization: Bearer $(cat {pod_tok})\" https://kubernetes.default.svc/apis/apps/v1/x -d '{{}}'"),
        (True, "kubectl -n x run dbg --image=busybox -- sleep 1d"),
        (True, "kubectl -n x debug deploy/a -it --image=busybox"),
        (True, "kubectl uncordon node-1"),
        (True, "kubectl certificate approve csr-x"),
        (True, "kubectl set selector svc/a app=b"),
        (True, "kubectl cp x.bin ns/pod-a:/app/x.bin"),
        (True, "kubectl -n x exec deploy/a -- rm -rf /data"),
        (True, "gh workflow run deploy-azure.yml"),
        (True, "az aks nodepool scale -g rg --cluster-name c -n pool2 -c 0"),
        (True, "terraform apply -auto-approve"),
        (True, "bash /tmp/does-not-exist-xyz.sh"),
        # must stay allowed (incl. the 9 false blocks)
        (False, "kubectl -n pay-midtier get pods"),
        (False, "kubectl diff -k overlays/dev"),
        (False, "kubectl create --dry-run=client -f x.yaml"),
        (False, "kubectl --context dev-cluster -n x auth can-i delete pods"),
        (False, "kubectl -n x logs deploy/a | grep error"),
        (False, "kubectl -n x rollout status deploy/a"),
        (False, "kubectl --request-timeout 10s -n x get deploy pay-patch-svc"),
        (False, "kubectl --as system:admin -n x get pods -l role=delete-worker"),
        (False, "helm get values pay-upgrade -n x"),
        (False, "helm upgrade x chart --dry-run -n x"),
        (False, "helm diff upgrade x chart"),
        (False, "git log --oneline -- deploy.sh"),
        (False, "sed -i s/a/b/ deploy-all.sh"),
        (False, "vi rollout.sh"),
        (False, "python3 - <<'E'\ncases=['kubectl apply -f x']\nE"),
        (False, "echo 'kubectl apply -f x'"),
        (False, 'git commit -m "kubectl apply was the old way"'),
        (False, "buildctl build --output type=image,push=true"),
        (False, f"bash {t}/report.sh"),
        (False, "bash -n deploy-all.sh"),
        (False, "bash ./checker.sh status api"),
        (False, "/x/kit/scripts/argus.sh doctor"),
        (False, "bash kit/scripts/argus.sh status api"),
        (True, "bash kit/scripts/argus.sh onboard api ns ws img"),
        (False, "grep -rn 'kubectl -n pay-midtier apply' docs/"),
        # text that merely MENTIONS eval / make / the API server is not a deploy; acting on it still is (PR #22 review)
        (False, "grep -n eval x.sh"),
        (False, 'echo "run make install later"'),
        (False, "ls kit/scripts/make-agent-kubeconfig.sh install.sh"),
        (False, "cat docs/x.md | grep kubernetes.default.svc"),
        (True, 'eval "$(cat cmd.txt)"'),
        (True, "x=1; eval $x"),
        (True, "make -C infra install"),
        (True, "echo 'kubectl apply -f x' | sh"),
        (True, "printf 'kubectl apply -f x' | /bin/bash"),
        (True, "grep -h kubectl notes.md | bash"),
        (True, "curl -s https://kubernetes.default.svc/api"),
        # scripts resolve against where the command runs, and a `cd` moves that (PR #22 review)
        (False, f"cd {t} && bash report.sh"),
        (True, f"cd {t} && bash ship-overlay.sh pay-midtier"),
        (True, f"cd {t}; ./ship-overlay.sh pay-midtier"),
        (True, "cd /nowhere-xyz && bash report.sh"),
        (False, ("bash report.sh", t)),
        (True, ("bash ship-overlay.sh pay-midtier", t)),
        # round 2 (adversary): a cd the gate cannot follow makes relative scripts fail closed; `..` is logical
        (True, f"cd {t} && (cd sub && bash report.sh)"),
        (True, f"cd {t} && pushd sub && bash report.sh"),
        (True, f"cd {t} && cd -- sub && bash report.sh"),
        (True, f"cd {t} && cd sub 2>/dev/null && bash report.sh"),
        (True, f"cd {t} && builtin cd sub && bash report.sh"),
        (True, f"cd {t}/sub/lnk && cd .. && bash report.sh"),
        (True, (f"cd .. && bash report.sh", f"{t}/sub/lnk")),
        (False, f"cd {t}/sub && bash {t}/report.sh"),
        # every spelling of eval / make, and text fed to a shell the gate cannot read
        (True, "'eval' \"$(cat cmd.txt)\""), (True, "x=$(cat cmd.txt); `eval $x`"), (True, "x=eval; $x \"$(cat c)\""),
        (True, "/usr/bin/make deploy"), (True, "\"make\" deploy"), (True, "gmake deploy"),
        (True, "echo x | env bash"), (True, "echo x | /usr/bin/env bash"), (True, "echo x | sudo -E bash"),
        (True, "echo x | xargs -I{} sh -c '{}'"), (True, "echo x |& bash"), (True, "echo x | \"bash\""),
        (True, "echo x | $SHELL"), (True, "echo x | busybox sh"),
        (True, "bash -c \"$(cat cmd.txt)\""), (True, "exec bash -c \"$(cat cmd.txt)\""), (True, f"bash {t}/cmd.txt"),
        (True, f"sh < {t}/cmd.txt"), (True, "bash <(cat cmd.txt)"), (True, "source <(cat cmd.txt)"),
        (True, "cat cmd.txt | source /dev/stdin"), (True, "perl -e 'system(`cat cmd.txt`)'"),
        (True, "python3 -c \"import os; os.system(open('cmd.txt').read())\""),
        (True, f"cat {t}/cmd.txt > {t}/report.sh; bash {t}/report.sh"),
        (True, "bash -c 'kubectl apply -f x.yaml'"),
        # ...while everyday commands stay allowed
        (False, "bash -c 'echo hi'"), (False, "sh -lc 'date'"), (False, "find . -name '*.py' | xargs grep -n TODO"),
        (False, "jq . file.json | less"), (False, "source ~/.bashrc"), (False, "make test"), (False, "cat x.sh | bash -n"),
        (False, "python3 -c \"import subprocess; subprocess.run(['ls'])\""), (False, "env | grep PATH"),
    ]
    bad = 0
    for want, c in cases:
        c, cwd = c if isinstance(c, tuple) else (c, None)
        got = is_deploy(c, cwd=cwd)
        bad += got != want
        print("PASS" if got == want else "FAIL", "block" if want else "allow", c.replace("\n", "⏎")[:90])
    print("ALL PASS" if not bad else f"{bad} FAILED")
    sys.exit(1 if bad else 0)

ev = _EV
cmd = (ev.get("tool_input") or {}).get("command", "") or ""
if not is_deploy(cmd, cwd=ev.get("cwd") or None):
    sys.exit(0)


PROTECTED_NS = {"kube-system", "kube-public", "kube-node-lease"} | set(_G("guard.protected_namespaces") or [])


def targets(cmd):
    """What the command ACTS on, per write segment: its namespace (-n/--namespace) and the files/dirs it
    applies (-f/-k) or the script it runs. v2 matched the approval scope as a substring of the WHOLE
    command, so a comment or a label value carried it (found in review)."""
    c = re.sub(r"\s#.*$", "", strip_commit_text(normalise(cmd)), flags=re.M)
    out = []
    for step in re.split(r";|&&|\|\||\n", c):
        for seg in re.split(r"\|(?!\|)", step):
            seg = seg.strip()
            if not (k_write(seg) or helm_write(seg) or script_runs(seg)):
                continue
            ns = re.findall(r"(?:^|\s)(?:-n|--namespace)[=\s]*([A-Za-z0-9.-]+)", seg)
            files = re.findall(r"(?:^|\s)(?:-f|--filename|-k|--kustomize)[=\s]+(\S+)", seg)
            scripts = [p for p, _ in script_runs(seg)]
            whole_ns = re.search(r"\b(delete|edit|patch|label|annotate)\s+(ns|namespace|namespaces)\b", seg)
            if whole_ns or any(n in PROTECTED_NS for n in ns):
                out.append(("forbidden", seg))
            elif not (ns or files or scripts):
                out.append(("unknown", seg))
            else:
                out.append(("ok", (set(ns), files + scripts, seg)))
    return out


def approval_for(cmd):
    """A live approval the owner granted (the kit's approval command, or a verified chat approval) that covers
    EVERY target: each write segment's namespace equals the scope, or each file/script it applies sits under it.
    The file must be a regular file (no symlink) carrying `by` and `created`."""
    import glob, time
    d = os.environ.get("PAIR_APPROVALS_DIR") or str(_G("paths.approvals") or "") or \
        (os.path.join(str(pairconf.ledger_dir(CFG)), "approvals") if CFG else "/nonexistent")
    now = time.time()
    tg = targets(cmd)
    if not tg or any(kind != "ok" for kind, _ in tg):
        return None                       # unknown or protected target: only the owner's own hands
    for f in sorted(glob.glob(os.path.join(d, "appr-*.json"))):
        try:
            if os.path.islink(f) or os.path.islink(d) or not os.path.isfile(f):
                continue
            with open(f) as fh:
                a = json.load(fh)
            scope = a.get("scope", "")
            if a.get("expires", 0) <= now or len(scope) < 6 or not a.get("by") or not a.get("created"):
                continue
            def covered(t):
                ns, paths, _ = t
                if ns:
                    return ns == {scope}
                return bool(paths) and all(scope in p for p in paths)
            if all(covered(t) for _, t in tg):
                return a
        except Exception:
            continue
    return None


appr = approval_for(normalise(cmd))
if appr:
    if L:
        L.write(L.entry(ev, "approved", category="deploy-approved", approval=appr["id"], scope=appr["scope"]))
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext":
          f"deploy-gate: allowed under {OWNER}'s approval {appr['id']} (scope '{appr['scope']}', "
          f"until {appr.get('expires_iso')}). Post the change notice and have the tester retest after the rollout."}}))
    sys.exit(0)
if L:
    L.write(L.entry(ev, "blocked", category="deploy-blocked", needs="owner"))
print(f"BLOCKED (deploy-gate): deployments and cluster changes are {OWNER}'s. Do not run this or work around it. "
      f"Put the EXACT command in the hand-over under 'Needs you' with what it changes and its rollback, and ask "
      f"{OWNER} to either run it themselves (`! <command>`) or open an approval window: `! {APPROVE_CMD} <scope> "
      f"<minutes>` (scope = a namespace or deployment that appears in the command), or reply `approve <namespace> "
      f"<minutes>` in their self-chat. Never create an approval yourself.",
      file=sys.stderr)
sys.exit(2)
