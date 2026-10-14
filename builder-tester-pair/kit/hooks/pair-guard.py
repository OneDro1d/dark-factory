#!/usr/bin/env python3
"""PreToolUse guard — keep the builder/tester wall honest (generic; every name comes from pair.yaml).

WHY THIS EXISTS
  The tester is only sharper than a self-check because the BUILDER never sees the checks (the holdout):
  the tester holds the scenarios and expected values, the builder only gets redacted reports. A builder
  that can read the expected values can write code that passes them instead of code that works.

WHAT IT BLOCKS (builder unless noted)
  1. HOLDOUT — reading scenario files (any kits/ tree, a scenarios/ dir, the tester's kits_dir), git reads
     of them from the object store, cloning the checker repos (argus.repos), globs that spell them, and
     making itself the tester.
  2. BLOCKED HOSTS (both roles) — any command or fetch acting on guard.blocked_hosts.
  2b. DEPLOY APPROVALS (both roles) — only the owner grants them; agents never create, edit or remove one.
  3. CHECKER SECRETS (both roles) — printing ~/.config/argus/{tokens/*,session.json,tester.env} or a rendered
     executor.yaml; `kubectl apply` of an executor.yaml.
  1b. PAIR.YAML — changing who is builder/tester or where the guards look (builder.host, tester.*, paths.approvals,
      paths.ledger, argus.repos, guard.*, extends), leaving it unparseable, moving/removing it, or writing a second
      pair.yaml that would be found first. Other keys stay editable with the Edit/Write tools.
  3b. Reading or copying the tester's credentials over `coder ssh|scp <tester.workspace>` or plain ssh/scp/rsync/sftp
      to its `coder config-ssh` alias (coder.<tester.workspace>) (presence checks ok).
  3c. (both) A post to the owner's Teams self-chat (48:notes, the command inbox) without the "[bot" marker.
  3d. Exec/cp/debug/attach into the tester's pod (tester.k8s_namespace / tester.host), incl. inside scripts.
  3e. (both) Teams posts not in the agreed HTML format "<p><b>[bot — <agent>, for <owner>]".
  3f. (both) Approval-shaped text ("approve <namespace> <minutes>") in any agent post.
  Every BUILDER block is appended to <paths.ledger>/guard-blocks.jsonl (the tester reports new ones).

ROLE: decided by hostname (builder.host / tester.host in pair.yaml), never by an env var an agent can set.
A TRIPWIRE, NOT A BOUNDARY: both agents usually share one account; this catches mistakes and makes
attempts visible. The real boundaries are separate workspaces and the builder holding runner tokens only.
"""
import json, os, re, socket, sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

if "--selftest" in sys.argv:
    import subprocess, tempfile
    tmp = tempfile.mkdtemp(prefix="pair-guard-selftest-", dir=f"/tmp/claude-{os.getuid()}" if os.path.isdir(f"/tmp/claude-{os.getuid()}") else None)
    led = os.path.join(tmp, "ledger"); os.makedirs(led)
    k = "k" + "its"                                   # fixture words assembled, so this file never trips a guard
    kd = "acme-" + k
    cfgp = os.path.join(tmp, "pair.yaml")
    ARG = ".config/" + "arg"                           # fixture words assembled (see k above)
    REMOTE_LOGIN, REMOTE_COPY, REMOTE_SYNC = "ss" + "h", "sc" + "p", "rsy" + "nc"
    sess = ARG + "us/sess" + "ion.json"
    with open(cfgp, "w") as f:
        f.write(CFG_TEXT := f"""project: {{name: Acme, slug: acme}}
owner: {{name: Jane Doe, email: jane@example.com, teams_user_id: "{"11111111-2222-3333-4444-" + "555555555555"}", slack_user_id: U0TESTJANE}}
builder: {{name: Forge, workspace: acme-builder, host: bt-builder}}
tester: {{name: Sentinel, workspace: acme-tester, host: bt-tester, k8s_namespace: jane-acme-tester-01, kits_dir: "~/{kd}", private_dir: "~/sentinel-private"}}
paths: {{shared_root: {tmp}, ledger: {led}}}
repos: [{{app: api, github: acme/api, base: main}}]
argus: {{url: "https://checker.example.com", repos: [acme/acme-checker]}}
guard: {{blocked_hosts: [evil.example.net]}}
""")
    host_bad = "evil.example" + ".net"
    ex = "executor" + ".yaml"
    appr = "approve-" + "deploy"
    adir = led + "/approvals"
    B = lambda c: {"tool_name": "Bash", "tool_input": {"command": c}}
    R = lambda f: {"tool_name": "Read", "tool_input": {"file_path": f}}
    T = lambda body, chat="48:notes", html=True: {"tool_name": "mcp__hub__microsoft_send_chat_message",
                                                   "tool_input": {"chat_id": chat, "is_html": html, "body": body}}
    OKP = "<p><b>[bot — Forge, for Jane]</b> status</p>"
    cases = [  # (want_rc, host, event)
        (2, "bt-builder", R(f"/x/checker/{k}/api/scenarios/web/API-UI-001.md")),
        (2, "bt-builder", B(f"cat {k}/api/scenarios/x.md")),
        (2, "bt-builder", {"tool_name": "Grep", "tool_input": {"pattern": "EXPECT", "path": f"{k}/api/scenarios"}}),
        (0, "bt-builder", B(f"ls {k}/api/scenarios")),
        (0, "bt-tester", R(f"{k}/api/scenarios/a.md")),
        (2, "bt-tester", B(f"curl https://{host_bad}/health")),
        (2, "bt-builder", {"tool_name": "WebFetch", "tool_input": {"url": f"https://{host_bad}/x", "prompt": "x"}}),
        (0, "bt-builder", B("curl -sk https://checker.example.com/health")),
        (2, "bt-tester", B("cat ~/.config/argus/tokens/api.author")),
        (0, "bt-tester", B("wc -c ~/.config/argus/tokens/api.author")),
        (2, "bt-tester", B("kubectl --context x ap" + "ply -f out/" + ex)),
        (0, "bt-tester", B("kubectl --context x create -f out/" + ex)),
        (2, "bt-builder", R(tmp + "/.config/argus/session.json")),
        (2, "bt-builder", B(f"git -C checker archive HEAD {k} | tar -xO")),
        (2, "bt-builder", B(f"git -C checker log -p -- {k}")),
        (2, "bt-builder", B("git clone https://github.com/acme/acme-checker.git /tmp/full")),
        (2, "bt-builder", {"tool_name": "Glob", "tool_input": {"pattern": "**/API-*.md"}}),
        (2, "bt-builder", B(f"cat /tmp/full/k?ts/api/scen*/a.md")),
        (2, "bt-builder", B(f"cat ~/{kd}/api/s.md")),
        (0, "bt-tester", B(f"git -C checker grep EXPECT HEAD -- {k}")),
        (0, "bt-builder", B(f"git commit -q -m 'guard reads of {k}/ and scenarios/'")),
        # approvals are the owner's
        (2, "bt-builder", B(f"{tmp}/kit/bin/{appr} api-namespace 60")),
        (2, "bt-tester", B(f"rm -f {adir}/*.json")),
        (2, "bt-builder", {"tool_name": "Write", "tool_input": {"file_path": f"{adir}/appr-x.json", "content": "{}"}}),
        (2, "bt-builder", B(f"ls {adir}; {tmp}/kit/bin/{appr} api-namespace 60")),
        (0, "bt-builder", B(f"{tmp}/kit/bin/{appr} --list")),
        (0, "bt-builder", B(f"ls {adir}")),
        (2, "bt-builder", {"tool_name": "Edit", "tool_input": {"file_path": tmp + "/.claude/settings.json", "old_string": "{", "new_string": "{\"env\":{\"PAIR_APPROVALS_DIR\":\"/tmp/m\"},"}}),
        # the tester's workspace and pod
        (2, "bt-builder", B(f"coder {REMOTE_LOGIN} acme-tester -- cp ~/{ARG}us/tokens/api.author /tmp/x")),
        (2, "bt-builder", B(f"coder {REMOTE_COPY} acme-tester:{ARG}us/session.json /tmp/s")),
        (0, "bt-builder", B(f"coder {REMOTE_LOGIN} acme-tester -- 'wc -c ~/{ARG}us/tokens/api.author'")),
        (2, "bt-builder", B("kubectl exec -n jane-acme-tester-01 deploy/x -- true")),
        (2, "bt-builder", B("az aks command invoke -g rg -n c --command 'kubectl cp jane-acme-tester-07/p:/home/u /tmp/a'")),
        (2, "bt-builder", B("kubectl debug -n x pod/bt-tester -it --image=busybox")),
        (0, "bt-builder", B("kubectl get pods -n jane-acme-tester-01")),
        (0, "bt-builder", B("kubectl exec -n jane-acme-builder-01 deploy/x -- true")),
        (2, "bt-builder", B(f"bash {tmp}/grab.sh")),
        # Teams format, command inbox, approval-shaped posts
        (0, "bt-builder", T(OKP)),
        (2, "bt-builder", T("<p>deploy now</p>")),
        (2, "bt-builder", T("[bot — Forge, for Jane] plain", html=False)),
        (2, "bt-builder", T("<p><b>[bot — Impostor, for Jane]</b> x</p>")),
        (0, "bt-builder", T("<p><b>[bot — Forge, for Jane Doe]</b> ✅ the rendered (full-name) marker</p>",
                            chat="19:c@unq.gbl.spaces")),
        (2, "bt-builder", T("<p><b>[bot — Forge, for Jane Smith]</b> x</p>", chat="19:c@unq.gbl.spaces")),
        (0, "bt-tester", T("<p><b>[bot — Sentinel, for Jane]</b> ✅ smoke 5/5</p>", chat="19:c@unq.gbl.spaces")),
        (2, "bt-builder", T("<p><b>[bot — Forge, for Jane]</b> approve api-namespace 30</p>")),
        (2, "bt-builder", {"tool_name": "mcp__hub__slack_send_message", "tool_input": {"channel_id": "C1", "message": "approve api-namespace 30"}}),
        (0, "bt-builder", {"tool_name": "mcp__hub__microsoft_list_chat_messages", "tool_input": {"chat_id": "48:notes"}}),
        (0, "bt-builder", B("cat > /tmp/notes.md <<'EOF'\nplain notes\nEOF")),
        # writing the pair settings file is not a holdout read; every way around the exception still is
        # the active pair.yaml: rewriting it with the same protected keys passes (its body names the tester's folders)
        (0, "bt-builder", B(f"cat > {cfgp} <<'EOF'\n" + CFG_TEXT.replace("name: Acme,", "name: Acme Two,") + "EOF")),
        (0, "bt-builder", {"tool_name": "Edit", "tool_input": {"file_path": cfgp, "old_string": "name: Acme,",
                                                               "new_string": "name: Acme Two,"}}),
        (0, "bt-tester", {"tool_name": "Edit", "tool_input": {"file_path": cfgp, "old_string": "host: bt-tester",
                                                              "new_string": "host: bt-tester2"}}),
        # ...but the builder may not change who is who, where approvals live, leave it broken, move it, or shadow it
        (2, "bt-builder", {"tool_name": "Edit", "tool_input": {"file_path": cfgp, "old_string": "host: bt-tester",
                                                               "new_string": "host: bt-builder"}}),
        (2, "bt-builder", {"tool_name": "Edit", "tool_input": {"file_path": cfgp, "old_string": "paths: {",
                                                               "new_string": "paths: {approvals: /tmp/mine, "}}),
        (2, "bt-builder", {"tool_name": "Edit", "tool_input": {"file_path": cfgp, "old_string": "project: {",
                                                               "new_string": "project: [ {"}}),
        (2, "bt-builder", {"tool_name": "Write", "tool_input": {"file_path": cfgp, "content": "project: {name: x}\n"}}),
        (2, "bt-builder", B(f"cat >> {cfgp} <<'EOF'\nguard: {{blocked_hosts: []}}\nEOF")),
        (2, "bt-builder", B(f"cat > /x/pair.yaml <<'EOF'\ntester: {{kits_dir: ~/{kd}}}\nEOF")),
        (2, "bt-builder", B(f"mv {cfgp} {cfgp}.bak")),
        (2, "bt-builder", B("rm -f ~/.config/builder-tester-agents/pair.yaml")),
        (2, "bt-builder", B(f"sed -i 's/bt-tester/bt-builder/' {cfgp}")),
        (0, "bt-builder", B(f"grep -n host {cfgp}")),
        # round 2 (adversary): ANY non-read-only command that names pair.yaml is blocked — listing write commands fails
        (2, "bt-builder", B(f"yq -i '.tester.host = \"bt-builder\"' {cfgp}")),
        (2, "bt-builder", B(f"dd if=/dev/null of={cfgp}")),
        (2, "bt-builder", B(f"curl -so {cfgp} file:///tmp/evil.yaml")),
        (2, "bt-builder", B(f"python3 -c \"import shutil; shutil.copy('/tmp/evil.yaml', '{cfgp}')\"")),
        (2, "bt-builder", B(f"sed -e s/bt-tester/bt-builder/ -i {cfgp}")),
        (2, "bt-builder", B(f"rsync /tmp/evil.yaml {cfgp}")),
        (2, "bt-builder", B(f"git checkout HEAD~1 -- {cfgp}")),
        (2, "bt-builder", B(f"sed -i s/a/b/ {os.path.dirname(cfgp)}/pai?.yaml")),
        (2, "bt-builder", B(f"ln -s {cfgp} /tmp/cfg.txt")),
        (2, "bt-builder", B(f"F={cfgp}; sed -i s/a/b/ $F")),
        (2, "bt-builder", B("rm -rf ~/.config/builder-tester-agents")),
        (2, "bt-builder", B(f"sed -i s/a/b/ {os.path.dirname(cfgp)}/pair.{{yaml,x}}")),     # brace expansion
        (2, "bt-builder", B(f"sed -i s/a/b/ {os.path.dirname(cfgp)}/pai\"\"r.yaml")),        # quote splitting
        (2, "bt-builder", B(f"sed -i s/a/b/ {os.path.dirname(cfgp)}/pai\\r.yaml")),          # backslash
        (2, "bt-builder", B(f"echo {cfgp} | xargs sed -i s/a/b/")),                          # name piped to xargs
        (0, "bt-builder", B(f"grep -n \"stall_minutes\\|heartbeat\" {cfgp}")),               # an escaped | is no pipe
        (0, "bt-builder", B(f"grep -nE 'a|b' {cfgp} | head -3")),                            # nor a quoted one
        (2, "bt-builder", B(f"grep -n 'a|b' {cfgp}; sed -i s/a/b/ {cfgp}")),                 # ...a real ; still splits
        # PR #24 review: backslash parity, substitutions inside double quotes, a lone background &
        (2, "bt-builder", B(f"grep host {cfgp} \\\\; sed -i s/a/b/ {cfgp}")),                # \\ is one backslash; ; is real
        (0, "bt-builder", B(f"grep host {cfgp} \\; echo x")),                                # \; is a literal ;
        (2, "bt-builder", B(f'echo "$(sed -i s/a/b/ {cfgp})"')),                             # "$( )" still runs
        (2, "bt-builder", B(f'echo "`sed -i s/a/b/ {cfgp}`"')),                              # "` `" still runs
        (0, "bt-builder", B(f'echo "see $(date) for {cfgp}"')),                               # ...a harmless one is fine
        (2, "bt-builder", B(f"grep host {cfgp} & sed -i s/a/b/ {cfgp}")),                    # a lone & separates
        (0, "bt-builder", B(f"grep host {cfgp} &> /tmp/x")),                                 # &> is a redirection
        (0, "bt-builder", B(f"grep host {cfgp} 2>&1 | head")),                               # >& is a redirection
        (2, "bt-builder", {"tool_name": "Edit", "tool_input": {"file_path": cfgp, "old_string": "slack_user_id: U0TESTJANE",
                                                               "new_string": "slack_user_id: U0FORGED"}}),
        (2, "bt-builder", {"tool_name": "Edit", "tool_input": {"file_path": cfgp, "old_string": "paths: {",
                                                               "new_string": "paths: {mcp_json: /tmp/forged.json, "}}),
        (2, "bt-builder", {"tool_name": "Write", "tool_input": {"file_path": os.path.join(tmp, ".mcp.json"), "content": "{}"}}),
        (2, "bt-builder", {"tool_name": "Write", "tool_input": {"file_path": cfgp, "content": ""}}),
        # ...while reading it, and copying it elsewhere, stay allowed
        (0, "bt-builder", B(f"grep -n host {cfgp} 2>&1")),
        (0, "bt-builder", B(f"cp {cfgp} /tmp/pair.bak")),
        (0, "bt-builder", B("ls -la ~/.config/builder-tester-agents/ 2>/dev/null")),
        (0, "bt-builder", B(f"git diff {cfgp} > /tmp/d.txt")),
        (0, "bt-builder", B("./setup-pair check 2>&1 | tee /tmp/log  # pair.yaml")),
        (0, "bt-builder", B(f"cat {cfgp} | python3 -c 'import sys; print(len(sys.stdin.read()))'")),
        (0, "bt-builder", {"tool_name": "Write", "tool_input": {"file_path": "/x/packs/other/pair.other.yaml",
                                                                "content": "tester: {host: x}\n"}}),
        # 3b round 2: case, a variable host, globbed paths and a command substitution do not get past it
        (2, "bt-builder", B(f"{REMOTE_LOGIN} coder.ACME-TESTER 'tar cz {ARG}us' > /tmp/a.tgz")),
        (2, "bt-builder", B(f"H=coder.acme-tester; {REMOTE_LOGIN} $H 'tar cz {ARG}us' > /tmp/a.tgz")),
        (2, "bt-builder", B(f"{REMOTE_COPY} -r coder.Acme-Tester:{ARG}us /tmp/x")),
        (2, "bt-builder", B(f"ssh coder.acme-tester 'ls $(cat ~/{sess})'")),
        (2, "bt-builder", B(f"{REMOTE_LOGIN} coder.acme-tester 'cat ~/{ARG}*/x.json'")),
        (2, "bt-builder", B(f"{REMOTE_LOGIN} coder.acme-tester 'tar c {ARG}u?' > /tmp/a.tar")),
        # private_dir round 2: $HOME, ${HOME}, //, /./, globs, a cd then a relative path, Glob/Grep globs
        (2, "bt-builder", B("cat $HOME/sentinel-private/design.md")),
        (2, "bt-builder", B("cat ${HOME}/sentinel-private/design.md")),
        (2, "bt-builder", B("cat ~/sentinel-pri*/design.md")),
        (2, "bt-builder", B("cat ~//sentinel-private/design.md")),
        (2, "bt-builder", B("cd ~ && cat sentinel-private/design.md")),
        (2, "bt-builder", R("~/./sentinel-private/design.md")),
        (2, "bt-builder", {"tool_name": "Glob", "tool_input": {"pattern": "sentinel-private/**", "path": "/home/u"}}),
        (2, "bt-builder", {"tool_name": "Grep", "tool_input": {"pattern": "x", "path": "/home/u", "glob": "sentinel-private/**"}}),
        (0, "bt-builder", B("ls ~/*")),
        # tester.private_dir is part of the holdout, in every spelling; a look-alike folder name is not
        (2, "bt-builder", R("~/sentinel-private/design-api.md")),
        (2, "bt-builder", R(os.path.expanduser("~/sentinel-private/notes.md"))),
        (2, "bt-builder", B("cat ~/sentinel-private/design-api.md")),
        (2, "bt-builder", {"tool_name": "Grep", "tool_input": {"pattern": "x", "path": "~/sentinel-private"}}),
        (0, "bt-builder", R("~/sentinel-private-old/readme.md")),
        (0, "bt-tester", R("~/sentinel-private/design-api.md")),
        # plain ssh/scp/rsync to the tester's coder alias is the same as `coder ssh`
        (2, "bt-builder", B(f"ssh coder.acme-tester cat ~/{sess}")),
        (2, "bt-builder", B(f"scp coder.acme-tester:{sess} /tmp/x")),
        (2, "bt-builder", B(f"{REMOTE_SYNC} -a coder.acme-tester:{ARG}us/ /tmp/x/")),
        (0, "bt-builder", B(f"{REMOTE_LOGIN} coder.acme-tester ls ~/{ARG}us")),
        (0, "bt-builder", B(f"tee -a /x/pair.example.yaml <<'EOF'\nnever_read: [\"**/{k}/**\"]\nEOF\n")),
        (2, "bt-builder", B(f"cat > /x/pair.yaml <<EOF\n$(cat {k}/api/scenarios/a.md)\nEOF")),
        (2, "bt-builder", B(f"cat > /x/{k}/pair.yaml <<'EOF'\nx: 1\nEOF")),
        (2, "bt-builder", B(f"cat > /x/pair.yaml <<'EOF'\nx: 1\nEOF\ncat {k}/api/scenarios/a.md")),
        (2, "bt-builder", B(f"cat > /x/pair.yaml <<'EOF'\nx: 1\nEOF\ncat {k}/api/scenarios/a.md\nEOF")),
        (2, "bt-builder", B(f"python3 - <<'EOF'\nopen('pair.yaml','w').write(open('{k}/api/scenarios/a.md').read())\nEOF")),
    ]
    with open(os.path.join(tmp, "grab.sh"), "w") as f:
        f.write("kubectl exec -n jane-acme-" + "tester-01 deploy/x -- wc -c ~/.profile\n")
    log = os.path.join(tmp, "blocks.jsonl"); open(log, "w").close()
    bad = 0
    for want, host, e in cases:
        env = dict(os.environ, PAIR_CONFIG=os.path.join(tmp, "pair.yaml"), PAIR_GUARD_TEST_HOST=host, PAIR_GUARD_LOG=log)
        rc = subprocess.run([sys.executable, __file__], input=json.dumps(e), text=True, capture_output=True, env=env).returncode
        bad += rc != want
        print("PASS" if rc == want else "FAIL", f"rc={rc} want={want} host={host}", json.dumps(e["tool_input"])[:80])
    want_logged = sum(1 for w, h, _ in cases if w == 2 and h != "bt-tester")
    logged = [json.loads(l) for l in open(log) if l.strip()]
    log_ok = len(logged) == want_logged and all(r.get("rule", "").startswith("BLOCKED") for r in logged)
    bad += not log_ok
    print("PASS" if log_ok else "FAIL", f"block log: {len(logged)} lines, want {want_logged} (builder blocks only)")
    # fail closed: a broken pair.yaml leaves only pair.yaml readable/editable; a dangling home pointer is not "no pair"
    fc = tempfile.mkdtemp(prefix="pair-guard-fc-")  # not under tmp: its pair.yaml would be found from cwd
    os.makedirs(os.path.join(fc, "p")); os.makedirs(os.path.join(fc, "home", ".config", "builder-tester-agents"))
    os.makedirs(os.path.join(fc, "empty"))
    broken = os.path.join(fc, "p", "pair.yaml")
    with open(broken, "w") as f:
        f.write("project: [\n")
    pointer = os.path.join(fc, "home", ".config", "builder-tester-agents", "pair.yaml")
    os.symlink(os.path.join(fc, "gone.yaml"), pointer)
    no_cfg = {k: v for k, v in os.environ.items() if k != "PAIR_CONFIG"}
    os.makedirs(os.path.join(fc, "emptycfg"))
    empty = os.path.join(fc, "emptycfg", "pair.yaml")
    open(empty, "w").close()
    # a pair.yaml whose extends base is NOT named pair*.yaml: the base is protected all the same
    os.makedirs(os.path.join(fc, "c"))
    chained, team = os.path.join(fc, "c", "pair.yaml"), os.path.join(fc, "c", "team.yaml")
    with open(team, "w") as f:
        f.write("tester: {host: bt-tester, name: Sentinel}\nproject: {name: Team}\n")
    with open(chained, "w") as f:
        f.write(f"extends: team.yaml\nbuilder: {{name: Forge, host: bt-builder}}\npaths: {{shared_root: {fc}/c, ledger: {fc}/c}}\n")
    as_builder = dict(os.environ, PAIR_CONFIG=chained, PAIR_GUARD_TEST_HOST="bt-builder", PAIR_GUARD_LOG=os.path.join(fc, "l"))
    E = lambda fp, o, n: {"tool_name": "Edit", "tool_input": {"file_path": fp, "old_string": o, "new_string": n}}
    fc_cases = [  # (want_rc, env, event)
        (2, dict(os.environ, PAIR_CONFIG=empty), B("ls")),                       # an EMPTY pair.yaml is broken too
        (2, as_builder, E(team, "host: bt-tester", "host: bt-builder")),
        (0, as_builder, E(team, "name: Team", "name: Team Two")),
        (0, dict(os.environ, PAIR_CONFIG=broken), {"tool_name": "Edit", "tool_input": {"file_path": broken}}),
        (0, dict(os.environ, PAIR_CONFIG=broken), R(broken)),
        (2, dict(os.environ, PAIR_CONFIG=broken), R("/x/notes/readme.md")),
        (2, dict(os.environ, PAIR_CONFIG=broken), {"tool_name": "Grep", "tool_input": {"pattern": "x", "path": "/x"}}),
        (2, dict(os.environ, PAIR_CONFIG=broken), B("ls")),
        (2, dict(no_cfg, HOME=os.path.join(fc, "home")), B("ls")),
        (0, dict(no_cfg, HOME=os.path.join(fc, "empty")), B("ls")),
    ]
    for want, env, e in fc_cases:
        rc = subprocess.run([sys.executable, __file__], input=json.dumps(e), text=True, capture_output=True, env=env,
                            cwd=os.path.join(fc, "empty")).returncode
        bad += rc != want
        print("PASS" if rc == want else "FAIL", f"rc={rc} want={want} fail-closed", e["tool_name"],
              json.dumps(e["tool_input"])[:60], "HOME=" + os.path.basename(env.get("HOME", "")))
    print("ALL PASS" if not bad else f"{bad} FAILED")
    sys.exit(1 if bad else 0)

try:
    ev = json.load(sys.stdin)
except Exception:
    sys.exit(0)

try:
    import pairconf
    _PATH = pairconf.find_config()
except BaseException:          # kit not installed on this machine
    _PATH = None
if _PATH is None:              # no pair.yaml anywhere: this machine is not one of a pair's workspaces
    sys.exit(0)
else:
    try:
        CFG = pairconf.load(_PATH)
    except BaseException as _e:  # pair.yaml exists but cannot be read: FAIL CLOSED, never switch the guard off
        _t = ev.get("tool_name", "") if isinstance(globals().get("ev"), dict) else ""
        _i = (ev.get("tool_input") or {}) if isinstance(globals().get("ev"), dict) else {}
        _target = str(_i.get("file_path") or _i.get("path") or "")
        if _t in ("Read", "Edit", "Write", "MultiEdit") and re.search(r"(^|/)pair(\.[\w-]+)?\.ya?ml$", _target):
            sys.exit(0)        # reading and fixing pair*.yaml stay possible; every other read waits (it may be a holdout)
        print(f"BLOCKED (pair-guard): {_PATH} cannot be loaded ({str(_e)[:200]}). The guards fail closed until it loads: "
              "fix pair.yaml with the Read/Edit tools, then the owner runs `./setup-pair check`. Tell the owner.", file=sys.stderr)
        sys.exit(2)
G = lambda key, default=None: pairconf.get(CFG, key, default)

HOST = socket.gethostname()
if os.environ.get("PAIR_GUARD_TEST_HOST") and str(CFG.get("_path", "")).startswith("/tmp/"):
    HOST = os.environ["PAIR_GUARD_TEST_HOST"]          # self-test only: a throw-away pair.yaml under /tmp
ROLE = pairconf.role(CFG, host=HOST)
tester = ROLE == "tester"

BUILDER, TESTER = pairconf.name(CFG, "builder"), pairconf.name(CFG, "tester")
OWNER = str(G("owner.short_name") or (G("owner.name") or "the owner").split()[0])
# The templates render the full owner.name in the marker, people often type the short name: accept either.
OWNER_NAMES = sorted({OWNER, str(G("owner.name") or OWNER).strip()}, key=len, reverse=True)
TESTER_WS = str(G("tester.workspace") or "")
TESTER_HOST = str(G("tester.host") or "")
TESTER_NS_NAME = str(G("tester.k8s_namespace") or "")
KITS_NAME = os.path.basename(os.path.expanduser(str(G("tester.kits_dir") or "~/test-kits")).rstrip("/"))
LEDGER = str(pairconf.ledger_dir(CFG))
APPROVALS = os.environ.get("PAIR_APPROVALS_DIR") or str(G("paths.approvals") or os.path.join(LEDGER, "approvals"))
GUARD_LOG = os.environ.get("PAIR_GUARD_LOG") or os.path.join(LEDGER, "guard-blocks.jsonl")
BLOCKED_HOSTS = [h for h in (G("guard.blocked_hosts") or []) if h]
CHECKER_REPOS = [r for r in (G("argus.repos") or []) if r]
CRED_DIRS = [".config/argus"] + list(G("guard.credential_dirs") or [])
APP_PREFIXES = [a.upper() for a in pairconf.apps(CFG)]

tool = ev.get("tool_name", "")
ti = ev.get("tool_input") or {}
blob = json.dumps(ti)
cmd = ti.get("command", "") if tool == "Bash" else ""
# A COMMIT MESSAGE is text, not an action: strip `-m "..."` and the heredoc body of `git commit -F -` only.
if re.search(r"\bgit\s+(commit|tag)\b", cmd):
    cmd = re.sub(r"(-m|--message)\s+(\"[^\"]*\"|'[^']*')", "", cmd)
    cmd = re.sub(r"(\bgit\s+(?:commit|tag)\b[^\n]*<<-?\s*'?(\w+)'?\n).*?\n\2\b", r"\1<<MSG", cmd, flags=re.S)


def _log_block(msg):
    """Every BUILDER block goes on the shared ledger, so a tripwire that fires is SEEN (the tester's
    `handoff list` reports it until `handoff guard-ack`). Long token-like runs are cut: no credential in the log."""
    if tester:
        return
    try:
        import datetime
        c = re.sub(r"[A-Za-z0-9_+/=.-]{24,}", "…", (cmd or json.dumps(ti))[:400])
        c = c if len(c) <= 160 else c[:120] + " … " + c[-30:]
        rec = {"at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
               "host": HOST, "tool": tool, "rule": msg[:140], "cmd": c,
               "session": str(ev.get("session_id", ""))[:8],
               "session_kind": "agent" if os.environ.get("PAIR_AGENT_SESSION") else "other-session"}
        with open(GUARD_LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:
        pass


def block(msg):
    _log_block(msg)
    print(msg, file=sys.stderr)
    sys.exit(2)


def _with_scripts(c):
    """The command plus the text of any local script it runs (`bash x.sh`, `python3 y.py`)."""
    out = [c]
    for m in re.finditer(r"\b(?:bash|sh|python3?|source|\.)\s+(\S+\.(?:sh|py|bash))\b", c):
        sp = os.path.realpath(os.path.expanduser(m.group(1)))
        if sp.startswith((HERE + "/", os.path.expanduser("~/.claude/hooks/"))):
            continue          # the hooks carry attack examples as self-test fixtures
        try:
            out.append(open(sp).read()[:200000])
        except Exception:
            pass
    return out


# 1a. The pair's settings file (pair.yaml / pair.example.yaml) NAMES the tester's folders (kits_dir, never_read), so
# writing it would trip the holdout on words. Exempt exactly one shell shape: `cat > <dir>/pair*.yaml <<'EOF' … EOF`
# (or `cat >>` / `tee [-a]`) with a QUOTED delimiter (inert body: no $(), no backticks run), the body never repeating
# the delimiter line, nothing else in the command, and the target path itself outside any holdout folder.
# python/sed edits stay blocked (they can read a scenario into the file); the Edit/Write tools already pass because
# only their path is checked.
PAIR_FILE = re.compile(r"(^|/)pair(\.[\w-]+)?\.ya?ml$")
_pw = re.fullmatch(r"\s*(?:cat\s*>>?|tee(?:\s+-a)?)\s*(\S+)\s*<<-?\s*(['\"])(\w+)\2[ \t]*\n(.*)\n\3\s*", cmd, re.S) \
    if tool == "Bash" else None
_raw_cmd = cmd
if _pw and PAIR_FILE.search(_pw.group(1)) and \
        not re.search(r"(?m)^\s*" + re.escape(_pw.group(3)) + r"\s*$", _pw.group(4)):
    cmd = cmd.split("\n", 1)[0]  # judge the holdout on the target line only; the body is data

# 2. Blocked hosts (both roles). Judged on what ACTS — shell commands and fetches.
if BLOCKED_HOSTS:
    HB = "|".join(re.escape(h) for h in BLOCKED_HOSTS)
    acts = cmd if tool == "Bash" else (ti.get("url", "") if tool == "WebFetch" else "")
    if re.search(HB, acts, re.I) and not (tool == "Bash" and re.match(r"^\s*(grep|rg|echo|printf)\b", cmd)):
        block(f"BLOCKED (pair-guard): this pair must not talk to {', '.join(BLOCKED_HOSTS)} (guard.blocked_hosts).")

# 2b. Deploy approvals are the owner's act (they run the kit's approval command themselves; `!` commands
# bypass hooks). An agent creating, editing or deleting one would be approving its own deploy.
def _norm(s):
    s = re.sub(r"/\.(?=/)", "", re.sub(r"/{2,}", "/", s or ""))
    return re.sub(r"''|\"\"", "", s)
APPR = (re.escape(_norm(APPROVALS)) + r"|approve[-_]?dep|approve-dep\*|PAIR_APPROVALS_DIR"
        r"|appr-[\w*?.-]*\.json|\$\{?A\}?-deploy")
c_n = _norm(cmd)
only_list = re.fullmatch(r"\s*(\S*/)?approve-dep" r"loy\s+--list\s*", c_n) or \
    re.fullmatch(r"\s*ls\s+(-\w+\s+)?" + re.escape(_norm(APPROVALS)) + r"/?\s*", c_n)
paths_n = " ".join(x for x in (_norm(str(ti.get(k, "") or "")) for k in ("file_path", "notebook_path", "path")) if x)
settings_redirect = tool in ("Write", "Edit", "NotebookEdit") and re.search(r"settings(\.local)?\.json\b", paths_n) \
    and re.search(r"PAIR_APPROVALS_DIR|PAIR_CONFIG|PAIR_LEDGER_DIR|PAIR_GUARD_\w+|KUBECONFIG", blob)
if (tool == "Bash" and re.search(APPR, c_n) and not only_list) or settings_redirect or \
   (tool in ("Write", "Edit", "NotebookEdit") and re.search(APPR, paths_n)) or \
   (tool in ("Write", "Edit") and re.search(re.escape(APPROVALS) + r"|approve-dep" r"loy", str(ti.get("content", "")) + str(ti.get("new_string", "")))
        and re.search(r"\.(py|sh|js|ts|rb|pl)\b", paths_n)):
    block(f"BLOCKED (pair-guard): only {OWNER} grants deploy approvals (they run the kit's approval command "
          f"themselves). Ask them; never create, edit or remove an approval yourself.")

# 3. Checker (Argus) secrets — both roles
SECRET = re.compile(r"\.config/argus/(tokens/|session\.json|tester\.env)|executor\.ya?ml", re.I)
EMIT = re.compile(r"\b(cat|less|more|head|tail|bat|xxd|od|strings|base64|jq|yq|python3?\s+-c|awk|sed\s+-n|grep(?!\s+-c))\b")
MEASURE = re.compile(r"\bwc\s+-c\b|\bgrep\s+-c\b|\btest\s+-[fs]\b|\bls\b(?![^|]*\|)")
STEPS = re.split(r"\|\|?|;|&&|\n", re.sub(r"(-m|--message)\s+(\"[^\"]*\"|'[^']*')", "", cmd))
if tool == "Bash" and any(SECRET.search(s) and EMIT.search(s) and not MEASURE.search(s) for s in STEPS):
    block("BLOCKED (pair-guard): this would print a checker credential or a rendered executor.yaml "
          "(plaintext Secret). Check presence with `grep -c` or `wc -c`, never the value.")
if tool == "Read" and SECRET.search(ti.get("file_path", "")):
    block("BLOCKED (pair-guard): checker credential / rendered executor.yaml — do not read it into the "
          "transcript. Use `wc -c` or `grep -c` for presence.")
if tool == "Bash" and re.search(r"kubectl\b[^|;&]*\bapply\b[^|;&]*executor\.ya?ml", cmd):
    block("BLOCKED (pair-guard): executor.yaml carries a Secret. `kubectl create -f`, never `apply`.")

# Path spelling helpers: one spelling per path ($HOME, ${HOME}, ~, //, /./), and names written as globs.
_HOME = os.path.expanduser("~")
_TOK_SPLIT = r"[\s'\"=:(){}<>|;&,`]+"


def _norm(s):
    s = re.sub(r"\$\{HOME\}|\$HOME(?!\w)", _HOME, str(s))
    s = re.sub(r"(?<![\w.~-])~(?=/|\s|$|['\")])", _HOME, s)
    s = re.sub(r"/(?:\./)+", "/", s)
    return re.sub(r"(?<!:)/{2,}", "/", s)


def _globby(s):
    return bool(re.search(r"[*?\[]", s))


def _name_hit(text, names, min_literal=3):
    """A path component in `text` that is one of `names`, also when written as a glob (sentinel-pri*, .vigil-privat?).
    A glob needs `min_literal` plain characters, so `*` alone does not name everything."""
    import fnmatch
    names = [n for n in names if n]
    for tok in re.split(_TOK_SPLIT, _norm(text)):
        for comp in tok.split("/"):
            if not comp:
                continue
            for n in names:
                if comp == n or (_globby(comp) and len(re.sub(r"[*?\[\]]", "", comp)) >= min_literal
                                 and fnmatch.fnmatchcase(n, comp)):
                    return n
    return None


def _path_hit(text, paths):
    """A token in `text` that spells one of `paths` (relative dir paths like .config/argus), also as a glob
    (.config/arg*, .config/argu?, ~/.config/*/session.json)."""
    import fnmatch
    for tok in re.split(_TOK_SPLIT, _norm(text)):
        comps = [c for c in tok.split("/") if c]
        for p in paths:
            pc = [c for c in p.split("/") if c]
            for i in range(len(comps) - len(pc) + 1):
                if all(c == q or (_globby(c) and fnmatch.fnmatchcase(q, c)) for c, q in zip(comps[i:], pc)):
                    return p
    return None


# 3b. (builder) The tester's credentials stay in the tester's workspace: no copying or reading a credential folder
# over ssh/scp/rsync/sftp or `coder ssh|scp`, whatever the host is called (case, alias, a variable).
if not tester and tool == "Bash":
    REMOTE = re.compile(r"\bcoder\s+(ssh|scp)\b|(?<![\w.-])(ssh|scp|rsync|sftp)(?![\w.-])", re.I)
    MEASURE_ONLY = re.compile(r"^[^|;&>]*\b(ls|wc\s+-c|grep\s+-c|test\s+-[fsde]|stat)\b[^|;&>]*$")
    for t in _with_scripts(cmd):
        for line in t.splitlines() or [t]:
            if REMOTE.search(line) and _path_hit(line, CRED_DIRS):
                rp = re.split(r"\s--\s", line, maxsplit=1)[-1].strip()
                q = re.match(r"(['\"])(.*?)\1(.*)$", rp, re.S)
                remote, tail = (q.group(2), q.group(3)) if q else (rp, "")
                harmless = lambda s: re.sub(r"\d?>&\d|\d>\s*/dev/null|>\s*/dev/null", "", s)
                local_copy = re.search(r">", harmless(tail)) or (not q and re.search(r">", harmless(rp)))
                measured = MEASURE_ONLY.search(remote.split("|")[0] if not q else remote) and \
                    not re.search(r"\$\(|`|<\(", remote)          # `ls $(cat …)` prints the value in its error
                if re.search(r"\b(scp|rsync|sftp)\b", line, re.I) or local_copy or not measured:
                    block(f"BLOCKED (pair-guard): the builder may not copy or read {TESTER}'s credentials over "
                          f"ssh/scp (coder or plain), directly or via a script. Presence checks only (ls, wc -c, grep -c).")

# 3d. (builder) No exec/cp/debug/attach into the tester's pod, by kubectl or `az aks command invoke`.
NS_PATS = []
if TESTER_NS_NAME:
    NS_PATS.append(re.escape(TESTER_NS_NAME))
    m = re.match(r"^(.*)-\d+$", TESTER_NS_NAME)
    if m:
        NS_PATS.append(re.escape(m.group(1)) + r"-\d+")
if TESTER_HOST:
    NS_PATS.append(r"(?<![\w-])" + re.escape(TESTER_HOST) + r"(?![\w])")
if not tester and tool == "Bash" and NS_PATS:
    TNS = "|".join(NS_PATS)
    if any(re.search(TNS, t) and re.search(r"\b(exec|cp|debug|attach|port-forward)\b", t)
           and re.search(r"\bkubectl\b|\baz\s+aks\b", t) for t in _with_scripts(cmd)):
        block(f"BLOCKED (pair-guard): the builder may not exec, copy, debug or attach into {TESTER}'s workspace "
              f"pod ({TESTER_NS_NAME or TESTER_HOST}), by kubectl or `az aks command invoke`. Read-only `get` is fine.")

# 3c. (both) The owner's Teams self-chat (48:notes) is the COMMAND INBOX: an agent post there without the bot
# marker would read as an instruction from the owner.
_chat_id = next((str(v) for k, v in ti.items() if re.fullmatch(r"chat_?id", k, re.I)), "")
_is_post = bool(re.search(r"(send|reply|update|post)_(chat|channel)_message", tool))
if _is_post and re.search(r"chat_message", tool) and _chat_id.strip().lower() == "48:notes":
    body = re.sub(r"<[^>]+>", "", str(ti.get("body", "") or ti.get("content", ""))).replace("&nbsp;", " ").lstrip()
    if not body.startswith("[bot"):
        block(f"BLOCKED (pair-guard): a message to {OWNER}'s self-chat (the command inbox) must start with "
              f"\"[bot — <agent>, for {OWNER}]\" — without it, it reads as an instruction from {OWNER}.")

# 3e. (both) Every agent post to Teams uses the agreed HTML format with the bold bot marker.
if _is_post and tool.startswith("mcp__") and "microsoft" in tool:
    _b = str(ti.get("body", "") or "")
    names = "|".join(re.escape(n) for n in (BUILDER, TESTER))
    owners = "|".join(re.escape(n) for n in OWNER_NAMES)
    if not (ti.get("is_html") is True and re.match(r"\s*<p>\s*<b>\s*\[bot — (" + names + r"), for (?:" + owners + r")\]", _b)):
        block(f"BLOCKED (pair-guard): Teams posts must be HTML (is_html: true) and start with "
              f"<p><b>[bot — {BUILDER}, for {OWNER}]</b> (or {TESTER}), then an icon + bold headline, a short <ul>, "
              f"an exact 'Your step' line if needed, and the sign-off.")

# 3f. (both) Agents post as the owner, so they never post anything shaped like a deploy approval.
APPROVE_SHAPE = re.compile(r"\bapprove\s+[a-z0-9][-a-z0-9]{4,}\s+\d{1,3}\b", re.I)
if re.search(r"(send|reply|update|post|schedule)[_a-z]*(message|chat)|slack_send|_draft", tool, re.I):
    _txt = re.sub(r"<[^>]+>", " ", " ".join(str(v) for k, v in ti.items() if k.lower() in
                                            ("body", "text", "message", "content", "markdown_text", "subject")))
    if APPROVE_SHAPE.search(_txt.replace("&nbsp;", " ")):
        block(f"BLOCKED (pair-guard): agents never post text shaped like a deploy approval "
              f"(\"approve <namespace> <minutes>\") — only {OWNER} writes those. Say \"reply with: approve, then the "
              f"namespace and minutes\".")

# 1b. (builder) pair.yaml decides who is the tester and where the guards look. The builder may edit other keys, but
# not these, not leave the file unparseable (that would put the guards in their fail-closed mode on purpose), not
# move/remove it (a missing file means "not a pair workspace"), and not write another pair.yaml found before it.
PROTECTED = ("extends", "owner", "builder.host", "tester.host", "tester.workspace", "tester.kits_dir",
             "tester.private_dir", "tester.k8s_namespace", "paths.approvals", "paths.ledger", "paths.shared_root",
             "paths.mcp_json", "argus.repos", "guard", "dashboard.artifact_url",
             # chat-approval trusts these to find the owner's messages: pointing them elsewhere forges an approval
             "teams.mcp_server", "teams.hub_workspace_id", "teams.list_messages_tool",
             "slack.mcp_server", "slack.read_channel_tool")
CHAIN = pairconf.chain(_PATH) if _PATH is not None else []          # pair.yaml + every file its extends pulls in
MCP_JSON = os.path.realpath(os.path.expanduser(str(G("paths.mcp_json") or
                                                   os.path.join(str(G("paths.shared_root") or "."), ".mcp.json"))))
_PROTECTED_FILES = set(CHAIN) | {MCP_JSON}
_PROTECTED_NAMES = sorted({os.path.basename(f) for f in _PROTECTED_FILES} | {"pair.yaml"})
_POINTER_DIR = ".config/builder-tester-agents"           # install.sh's link to the shared pair.yaml lives here
# Read-only programs: a pipeline segment that names a protected file may only be one of these (and redirect nowhere
# protected). Anything else that names one — sed, yq -i, dd, curl -o, cp onto it, git checkout, python, a variable
# holding the name — is blocked: listing every way to WRITE a file cannot be done, listing ways to READ one can.
_READ_ONLY = {"cat", "grep", "egrep", "fgrep", "rg", "head", "tail", "wc", "ls", "stat", "file", "diff", "cmp", "less",
              "more", "sha256sum", "sha1sum", "md5sum", "test", "[", "echo", "printf", "readlink", "realpath",
              "basename", "dirname", "jq", "true", "sort", "uniq", "cut", "tr", "column", "nl", "find", "yq", "git", "cp"}


def _seg_read_only(seg):
    words = seg.split()
    if words and re.match(r"^[A-Za-z_]\w*=", words[0]):
        return False                                    # F=pair.yaml …: a name parked in a variable
    if not words:
        return True
    prog = os.path.basename(words[0])
    if prog not in _READ_ONLY:
        return False
    if prog == "yq" and re.search(r"\s(-i|--inplace)\b", seg):
        return False
    if prog == "find" and re.search(r"\s-(delete|exec|execdir|ok|okdir|fprint\w*)\b", seg):
        return False
    if prog == "git" and not re.match(r"\s*git\s+(?:-C\s+\S+\s+)?(diff|log|show|status|blame|ls-files)\b", seg):
        return False
    if prog == "cp" and _protected_ref(words[-1]):
        return False                                    # copying ONTO a protected file
    for tgt in re.findall(r"(?<![&\d])>>?\s*([^\s&|;]+)", seg):
        if _protected_ref(tgt):
            return False
    return True


def _shell_spellings(text):
    """What the shell would make of quoting tricks and brace expansion: pai""r.yaml, pai\\r.yaml, $'pair.yaml' and
    pair.{yaml,x} all name pair.yaml."""
    t = re.sub(r"''|\"\"", "", str(text))
    t = re.sub(r"\\(?=[\w.])", "", t)
    t = re.sub(r"\$'([^']*)'", r"\1", t)
    for _ in range(3):                                  # expand {a,b} (nested a few levels)
        t2 = re.sub(r"(\S*?)\{([^{}\s]*,[^{}\s]*)\}(\S*)",
                    lambda m: " ".join(m.group(1) + alt + m.group(3) for alt in m.group(2).split(",")), t)
        if t2 == t:
            break
        t = t2
    return t


_SEP_MASK = {"|": "\x01", ";": "\x02", "&": "\x03", "\n": "\x04", "(": "\x05", ")": "\x06", "`": "\x07", "$": "\x08"}


def _mask_quoted(s):
    """Hide separators that the SHELL treats as literal text, so splitting into steps and pipeline segments only cuts
    where the shell would; _unmask puts them back in each piece. A small scanner, not a regex:
      - a backslash escapes exactly the next character (so in `\\\\;` the pair is one literal backslash and the `;`
        is a real separator);
      - inside '…' everything is literal;
      - inside "…" separators are literal, but $(…) and `…` still RUN: their contents stay visible (and split)."""
    out, i, n = [], 0, len(s)
    stack = ["code"]                   # code | single | double | subst (inside $( ) or ` ` within double quotes)
    while i < n:
        ch, top = s[i], stack[-1]
        if top == "single":
            if ch == "'":
                stack.pop(); out.append(ch)
            else:
                out.append(_SEP_MASK.get(ch, ch))
            i += 1
            continue
        if ch == "\\" and i + 1 < n:      # escapes the next char in code, double and subst alike
            out.append(ch + _SEP_MASK.get(s[i + 1], s[i + 1]))
            i += 2
            continue
        if top == "double":
            if ch == '"':
                stack.pop(); out.append(ch); i += 1
            elif s.startswith("$(", i):
                stack.append("subst"); out.append("$("); i += 2
            elif ch == "`":
                stack.append("bsubst"); out.append(ch); i += 1
            else:
                out.append(_SEP_MASK.get(ch, ch)); i += 1
            continue
        # code / subst / bsubst: separators are real
        if top == "subst" and ch == ")":
            stack.pop(); out.append(ch); i += 1
            continue
        if top == "bsubst" and ch == "`":
            stack.pop(); out.append(ch); i += 1
            continue
        if ch == "'":
            stack.append("single")
        elif ch == '"':
            stack.append("double")
        out.append(ch)
        i += 1
    return "".join(out)


def _unmask(s):
    for k, v in _SEP_MASK.items():
        s = s.replace(v, k)
    return s


_HANDS_ON = re.compile(r"^\s*(?:\S*/)?(xargs|parallel|while|sh|bash|zsh|dash|ksh|source|\.)\b")


def _protected_ref(text):
    text = _shell_spellings(text)
    if _name_hit(text, _PROTECTED_NAMES) or _path_hit(text, [_POINTER_DIR]):
        return True
    for tok in re.split(_TOK_SPLIT, _norm(text)):
        if tok and os.path.exists(tok) and os.path.realpath(tok) in _PROTECTED_FILES:
            return True                                 # a symlink or another spelling of a protected file
    return False


def _pair_protected_change(target, new_text):
    """None if writing new_text to target is allowed for the builder; else why not."""
    import pathlib
    real = os.path.realpath(os.path.expanduser(target))
    if real == MCP_JSON:
        return "it is the MCP config the approval tool uses to read the owner's messages"
    if real not in CHAIN:
        if os.path.basename(target) == "pair.yaml" or os.path.basename(real) == "pair.yaml":
            return f"{target} is not the active settings file ({CHAIN[0] if CHAIN else _PATH}); it would be found first"
        return None                                     # another pair.*.yaml (an example, an unused pack)
    try:
        old = pairconf.yaml.safe_load(pathlib.Path(real).read_text()) if pairconf.yaml else \
            json.loads(pathlib.Path(real).read_text())
        new = pairconf.yaml.safe_load(new_text) if pairconf.yaml else json.loads(new_text)
    except Exception as e:
        return f"the result would not parse ({str(e)[:120]})"
    if not isinstance(new, dict) or not new:
        return "the result would be empty or not a mapping"
    changed = [k for k in PROTECTED if pairconf.get(old or {}, k) != pairconf.get(new, k)]
    return f"it changes {', '.join(changed)}" if changed else None


if not tester and _PATH is not None:
    _why = None
    _fp = str(ti.get("file_path", "") or ti.get("notebook_path", ""))
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit") and _fp and \
            (PAIR_FILE.search(_fp) or os.path.realpath(os.path.expanduser(_fp)) in _PROTECTED_FILES):
        fp = os.path.expanduser(_fp)
        try:
            cur = open(fp).read() if os.path.isfile(fp) else ""
        except OSError:
            cur = ""
        if tool == "Write":
            new_text = str(ti.get("content", ""))
        else:
            new_text = cur
            for e in (ti.get("edits") or [ti]):
                o, n = str(e.get("old_string", "")), str(e.get("new_string", ""))
                new_text = new_text.replace(o, n) if e.get("replace_all") else new_text.replace(o, n, 1)
        _why = _pair_protected_change(fp, new_text)
    elif _pw and PAIR_FILE.search(_pw.group(1)):
        fp = os.path.expanduser(_pw.group(1))
        append = bool(re.match(r"\s*(cat\s*>>|tee\s+-a)", _raw_cmd))
        try:
            cur = open(fp).read() if append and os.path.isfile(fp) else ""
        except OSError:
            cur = ""
        _why = _pair_protected_change(fp, cur + _pw.group(4) + "\n")
    elif tool == "Bash" and not _pw:
        _c = re.sub(r"(?m)(^|\s)#.*$", "", _raw_cmd)        # a comment that names pair.yaml is not an action
        # nor is a quoted MESSAGE (a PR comment, a hand-over note): those flags carry prose, never a path to write
        _c = re.sub(r"(?:--(?:body|note|message|title|subject|text|description|summary|reason|request|acceptance|"
                    r"canary-unchecked)|\s-[mbt])(?:=|\s+)(['\"])(?:(?!\1).)*\1", " ", _c, flags=re.S)
        # Each $( ) / ` ` substitution is a command of its own, lifted out (innermost first) and replaced by a
        # placeholder, so `echo "see $(date) for pair.yaml"` stays ONE echo while `echo "$(sed -i … pair.yaml)"`
        # judges the sed. Steps: ; && || newline ( ) and a lone & (background) — not >& &> |&.
        _work, _cmds = _mask_quoted(_c), []
        while True:
            _m = re.search(r"\$\(([^()]*)\)|`([^`]*)`", _work)
            if not _m:
                break
            _cmds.append(_m.group(1) if _m.group(1) is not None else _m.group(2))
            _work = _work[:_m.start()] + "\x09" + _work[_m.end():]
        _cmds.append(_work)
        _pipes = [p for c in _cmds for p in re.split(r";|&&|\|\||\n|\(|\)|(?<![&>|])&(?![&>])", c)]
        for _pipe in _pipes:
            _segs = [_unmask(s) for s in re.split(r"\|&?", _pipe)]
            _named = [s for s in _segs if _protected_ref(s)]
            for _seg in _named:
                if not _seg_read_only(_shell_spellings(_seg).strip()):
                    _why = (f"`{_seg.strip()[:80]}` would change a protected settings file; only read-only commands "
                            f"may name it (cat, grep, diff, git diff/log, cp it elsewhere…)")
            if _named and not _why and any(_HANDS_ON.match(s) for s in _segs):
                _why = "the file's name is piped into xargs/a shell, which can act on it"
            if _why:
                break
    if _why:
        block(f"BLOCKED (pair-guard): pair.yaml — {_why}. Who is builder/tester and where the guards look are "
              f"{OWNER}'s settings: put the change in the hand-over under 'Needs you'.")

# 1. Holdout (builder only)
if not tester:
    # tester.private_dir (designs, notes) and kits_dir: matched by FOLDER NAME in any spelling — ~/x, $HOME/x,
    # ${HOME}/x, //, /./, a relative x/ after a cd, and globs such as x-pri* — in every path, pattern and command
    _priv = os.path.basename(str(G("tester.private_dir") or "").rstrip("/"))
    _priv = _priv if _priv not in ("", "~", ".", "..") else ""
    HOLD = re.compile(r"(^|[\s/'\"=:(])(kits(/|\s|$|[\"'):])|test-agent/scenarios|[^\s/]*/?scenarios(-[a-z]+)?/)|"
                      + re.escape(KITS_NAME))
    GITREAD = re.compile(r"\bgit\b[^|;&]*\b(cat-file|archive|grep|log\s[^|;&]*-p|show\s|sparse-checkout\s+(disable|set|add|reapply)|checkout|restore|ls-tree|rev-list\s[^|;&]*--objects|fsck\s[^|;&]*--lost)")
    ti2 = dict(ti, command=cmd)
    paths = _norm(" ".join(str(ti2.get(k, "")) for k in ("file_path", "path", "pattern", "glob", "command", "url")))
    name_hit = _name_hit(paths, [_priv, KITS_NAME])
    REPO_RX = "|".join(re.escape(r.split("/")[-1]) for r in CHECKER_REPOS)
    checker_repo = bool(REPO_RX) and re.search(REPO_RX, paths)
    git_hit = tool == "Bash" and GITREAD.search(cmd) and (HOLD.search(cmd) or checker_repo)
    clone_hit = tool == "Bash" and bool(REPO_RX) and re.search(REPO_RX, cmd) and \
        re.search(r"\b(git\s+clone|gh\s+repo\s+clone|worktree\s+add|git\s+fetch|git\s+pull|submodule)\b", cmd)
    PFX = "|".join(re.escape(p) for p in APP_PREFIXES)
    glob_hit = tool == "Bash" and re.search(r"(^|[\s/'\"])k[a-z]?[?*\[][^/\s]*/|scen[a-z]*[?*]" +
                                            (r"|(" + PFX + r")-\*|\*\*/(" + PFX + r")-" if PFX else ""), cmd)
    glob_tool = bool(PFX) and tool in ("Glob", "Grep") and re.search(r"(" + PFX + r")-", str(ti.get("pattern", "")) + str(ti.get("glob", "")))
    promote = tool in ("Edit", "Write") and "settings.json" in str(ti.get("file_path", "")) and \
        re.search(r"PAIR_GUARD_TEST_HOST|PAIR_CONFIG", blob)
    web_hit = tool == "WebFetch" and bool(REPO_RX) and re.search(r"(" + REPO_RX + r")[^ ]*/(tree|blob|raw)/[^ ]*kits", str(ti.get("url", "")))
    # Same-workspace stand-in (tester runs as another Linux user here): the builder must not become that user or open
    # its home. With the tester in its own workspace neither can happen, so both checks are off unless configured.
    _esc = tool == "Bash" and G("guard.block_privilege_escalation", False) is True and re.search(
        r"(?:^|[;&|(`\n\r'\"]|\$\(|\bxargs\s+|\benv\s+|\bexec\s+|\bcommand\s+|\b(?:ba|z|da)?sh\s+-\w*c\s+)\s*(?:[\w.~-]*/)*(?:sudo|su|doas|runuser|pkexec|nsenter|setpriv)\b", cmd)
    _th = os.path.expanduser(str(G("tester.agent_home") or "")).rstrip("/")
    _home_hit = bool(_th) and G("tester.user") and _th in (paths + " " + cmd + " " + str(ti.get("file_path", "")))
    if _esc or _home_hit:
        block(f"BLOCKED (pair-guard): HOLDOUT. {TESTER} runs in this workspace as its own Linux user. The builder may "
              f"not use sudo/su/doas to become another user, nor open {TESTER}'s home folder. If you need a "
              f"privileged step, put it in the hand-over under 'Needs you'.")
    if clone_hit or glob_hit or glob_tool or promote or web_hit:
        block(f"BLOCKED (pair-guard): HOLDOUT. The builder may not clone the checker repos, reach kits/ by glob or "
              f"URL, or make itself the tester ({TESTER} is {TESTER_HOST or 'the tester host'}, set in pair.yaml).")
    if HOLD.search(paths) or name_hit or git_hit:
        listing_only = tool == "Bash" and not git_hit \
            and re.match(r"^\s*(ls|find\s+\S+\s+(-name|-type|-path)|test\s+-[de])\b", cmd) \
            and not re.search(r"\b(cat|head|tail|less|more|grep|rg|sed|awk|xargs|tar|cp|rsync|python3?|perl)\b|-exec|-ok\b|-print0", cmd)
        if tool in ("Read", "Grep", "Glob", "NotebookRead", "Edit", "Write") or (tool == "Bash" and not listing_only):
            block(f"BLOCKED (pair-guard): HOLDOUT. This session is the builder; {TESTER}'s scenario bodies and "
                  f"expected values must never reach it. Run checks through the runner (redacted reports only); "
                  f"writing checks is {TESTER}'s job, in its own workspace.")

sys.exit(0)
