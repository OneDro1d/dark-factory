#!/usr/bin/env bash
# SessionStart — tell the agent which role it plays in this pair and the rules that go with it.
# Role = this machine's hostname matched against builder.host / tester.host in pair.yaml (kit/lib/pairconf.py).
# Kept terse: it is prepended to every session.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PC="python3 $HERE/../lib/pairconf.py"
ROLE="$($PC role 2>/dev/null || echo unknown)"
[ "$ROLE" = builder ] || [ "$ROLE" = tester ] || exit 0          # not one of the pair's workspaces: say nothing
get() { $PC get "$1" 2>/dev/null; }
PROJECT="$(get project.name)"; OWNER="$(get owner.name)"; OWNER_SHORT="$(get owner.short_name)"
[ -n "$OWNER_SHORT" ] || OWNER_SHORT="${OWNER%% *}"
BUILDER="$(get builder.name)"; TESTER="$(get tester.name)"
ME="$( [ "$ROLE" = builder ] && echo "$BUILDER" || echo "$TESTER")"
KIT_BIN="$(cd "$HERE/../bin" && pwd)"
MAXR="$(get rules.max_rounds)"; MAXR="${MAXR:-3}"
MEM="$(get engram.${ROLE}_memory)"; BEH="$(get engram.${ROLE}_behaviors)"; SES="$(get engram.sessions_${ROLE})"; KNOW="$(get engram.knowledge)"

if [ "$ROLE" = builder ]; then
read -r -d '' ROLE_TXT <<EOF
**Your role: BUILDER.** ${TESTER} is product owner + architect + tester; you only build.
- New work (from anyone, any channel): do NOT build yet and NEVER write acceptance criteria. Forward it VERBATIM:
  \`${KIT_BIN}/handoff request --app <app> --request "<verbatim>" --requester "<name>" --where <link>\`.
- Build ONLY hand-overs in state to-builder, exactly to ${TESTER}'s acceptance + design (\`handoff show <id>\`);
  restate the spec in your own words first; if your reading differs, \`handoff escalate <id>\` — never guess.
- Unit tests first, then \`handoff fix <id> --pr .. --commit <40-hex> --deploy-cmd-file .. --rollback-file ..\`.
  ${TESTER} tests that commit locally; a failure comes back to you (max ${MAXR} rounds).
- You never read ${TESTER}'s tests or expected values (pair-guard blocks it and logs every attempt).
- Deploys are ${OWNER_SHORT}'s: hand over the exact command + rollback; deploy only inside an approval window
  ${OWNER_SHORT} opened (deploy-gate enforces). Never create or touch an approval. Never merge.
EOF
else
read -r -d '' ROLE_TXT <<EOF
**Your role: TESTER — product owner + architect + tester.** ${BUILDER} only builds, to your spec.
- New work: clarify it with the requester (\`${KIT_BIN}/handoff ask\`), write the requirement + measurable acceptance
  (Given/When/Then) + a short design, then \`handoff spec <id> ...\` (or \`handoff spec-open ...\` for work sent to you).
- Expected answers come from the requirement only — never copied from the code or the knowledge pages.
- Your test cases, inputs and expected values never go to ${BUILDER}, a spec, the shared disk or git. Put a leak
  marker (\`${KIT_BIN}/canary new\`) in your tests; \`handoff result ... PASS\` checks ${BUILDER}'s work for it.
- Test the exact commit locally (no deploy), then live after ${OWNER_SHORT} deploys; judge each failure: real bug,
  wrong test, flaky, or unclear requirement. Max ${MAXR} rounds each, then escalate.
- \`handoff list --for tester\` every tick; report new guard blocks to ${OWNER_SHORT}, then \`handoff guard-ack\`.
EOF
fi

read -r -d '' TXT <<EOF
## You are ${ME} — ${OWNER}'s ${ROLE} agent for ${PROJECT}. Rules loaded at start (from pair.yaml).

${ROLE_TXT}

$(python3 "$HERE/../lib/rules.py" session "$ROLE" 2>/dev/null || echo "- (rules could not be generated from pair.yaml: run ./setup-pair check)")
EOF
python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.stdin.read()}}))' <<< "$TXT"
