#!/usr/bin/env python3
"""PreToolUse(*) + PostToolUse(*) — every action the builder / tester ATTEMPTED and COMPLETED, on a ledger the
owner can review: <paths.ledger>/<date>.jsonl (from pair.yaml).

WHY TWO PHASES
  PostToolUse never fires for a failed command or for a call another hook blocked, so failures and
  denials would be invisible. phase=attempt at PreToolUse (every call, before any guard decides) and
  phase=done at PostToolUse (the call ran). An attempt with no done (same id) = failed, denied or refused.

PRIVACY
  Masking, the tester's program-name-only rule and categories live in ledger_common.py (shared with
  deploy-gate.py). The tester's arguments, patterns, descriptions and subjects are never logged — any of
  them can be an expected value.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger_common as L  # noqa: E402

if "--selftest" in sys.argv:
    import tempfile, glob
    d = tempfile.mkdtemp(dir="/tmp")
    os.environ["PAIR_LEDGER_DIR"] = d
    FAKES = ["odts_FAKEFAKEFAKE1234", "FAKEPW_spaceform", "FAKEPW_basicauth", "FAKEPW_inurl", "FAKEPW_json",
             "FAKEOPAQUEtoken123456", "FAKEPATvalue12345", "FAKEPW_eq", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig"]
    cases = [  # (agent, tool, input, want_category)
        ("builder", "Bash", {"command": "kubectl -n x get pods"}, "cluster-read"),
        ("builder", "Bash", {"command": "kubectl -n x run dbg --image=busybox"}, "cluster-write"),
        ("builder", "Bash", {"command": "kubectl -n x \\\n  apply -f y"}, "cluster-write"),
        ("builder", "Bash", {"command": "curl -X PATCH https://kubernetes.default.svc/apis/apps/v1/x"}, "cluster-write"),
        ("builder", "Bash", {"command": "gh workflow run cd.yml"}, "ci-trigger"),
        ("builder", "Bash", {"command": "mysql --password FAKEPW_spaceform -h db"}, "other"),
        ("builder", "Bash", {"command": "curl -u admin:FAKEPW_basicauth https://x"}, "other"),
        ("builder", "Bash", {"command": "git clone https://user:FAKEPW_inurl@github.com/a/b"}, "other"),
        ("builder", "Bash", {"command": "echo '{\"password\": \"FAKEPW_json\"}' | jq ."}, "other"),
        ("builder", "Bash", {"command": "curl -H 'Authorization: Bearer FAKEOPAQUEtoken123456' x"}, "other"),
        ("builder", "Bash", {"command": "export WAREHOUSE_PAT=FAKEPATvalue12345"}, "other"),
        ("builder", "Bash", {"command": "x password=FAKEPW_eq y; curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig'"}, "other"),
        ("builder", "Bash", {"command": "curl -H 'X-App-Secret: odts_FAKEFAKEFAKE1234' x"}, "other"),
        ("tester", "Bash", {"command": "printf 'expect=FAKE_EXPECTED_VALUE_43' > s.md"}, "other"),
        ("tester", "Bash", {"command": "git -C ~/x push origin main"}, "git-push"),
        ("tester", "Grep", {"pattern": "FAKE_EXPECTED_VALUE_46", "path": "/tmp"}, "read"),
        ("tester", "Agent", {"subagent_type": "general-purpose", "description": "assert total == FAKE_EXPECTED_VALUE_47"}, "agent"),
        ("tester", "mcp__x__microsoft_send_channel_message", {"channel_id": "c", "subject": "expected FAKE_EXPECTED_VALUE_48"}, "outbound-post"),
        ("builder", "mcp__x__jira_add_comment", {"issue_key": "PAY-1", "body": "x"}, "jira-write"),
    ]
    bad = 0
    for i, (agent, tool, ti, want) in enumerate(cases):
        os.environ["PAIR_LEDGER_TEST_ROLE"] = agent
        e = L.entry({"tool_name": tool, "tool_input": ti, "tool_use_id": f"t{i}"}, "attempt")
        leak = [f for f in FAKES + [f"FAKE_EXPECTED_VALUE_{n}" for n in (43, 46, 47, 48)] if f in json.dumps(e)]
        ok = e["category"] == want and not leak
        bad += not ok
        print("PASS" if ok else "FAIL", f"{agent:7} {e['category']:14} want={want:14} leak={leak} | {e['summary'][:60]}")
    # attempt + done pairing through the real entrypoint
    os.environ["PAIR_LEDGER_TEST_ROLE"] = "builder"
    import subprocess
    for phase_ev in ("PreToolUse", "PostToolUse"):
        subprocess.run([sys.executable, __file__], input=json.dumps({"hook_event_name": phase_ev, "tool_name": "Bash",
                        "tool_use_id": "pair1", "tool_input": {"command": "false"}}), text=True, env=dict(os.environ))
    rows = []
    for f in glob.glob(d + "/*.jsonl"):
        with open(f) as fh:
            rows += [json.loads(l) for l in fh]
    phases = sorted(r["phase"] for r in rows if r.get("id") == "pair1")
    ok = phases == ["attempt", "done"]
    bad += not ok
    print("PASS" if ok else "FAIL", "attempt+done pairing:", phases)
    # pair.yaml present but broken: entries still land (in this home's fallback folder), as privately as the tester's
    home = tempfile.mkdtemp(dir="/tmp")
    broken = os.path.join(home, "pair.yaml")
    with open(broken, "w") as fh:
        fh.write("paths: [\n")
    env = {k: v for k, v in os.environ.items() if k not in ("PAIR_LEDGER_DIR", "PAIR_LEDGER_TEST_ROLE")}
    env.update(HOME=home, PAIR_CONFIG=broken)
    subprocess.run([sys.executable, __file__], input=json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                    "tool_use_id": "fb1", "tool_input": {"command": "printf 'expect=FAKE_EXPECTED_VALUE_49' > s.md"}}),
                   text=True, env=env)
    fb = []
    for f in glob.glob(home + "/.cache/builder-tester-agents/ledger-fallback/*.jsonl"):
        with open(f) as fh:
            fb += [json.loads(l) for l in fh]
    ok = len(fb) == 1 and fb[0].get("config_error") and "FAKE_EXPECTED_VALUE_49" not in json.dumps(fb[0])
    bad += not ok
    print("PASS" if ok else "FAIL", "broken pair.yaml -> fallback ledger, private:", [r.get("summary") for r in fb])
    print("ALL PASS" if not bad else f"{bad} FAILED")
    sys.exit(1 if bad else 0)

try:
    ev = json.load(sys.stdin)
except Exception:
    sys.exit(0)
phase = "done" if ev.get("hook_event_name") == "PostToolUse" else "attempt"
L.write(L.entry(ev, phase))
sys.exit(0)
