# Rules: where every rule the agents follow comes from

Everything the two agents obey is generated from `pair.yaml`. Nothing is typed into a template by hand, so
changing a setting changes the behaviour of both agents at the next `./setup-pair render` (listener rules) and the
next session start (operating rules).

```
pair.yaml (+ extends: packs/<org>/pair.<org>.yaml)
   │
   ├─ kit/lib/rules.py ──► SessionStart hook: operating rules, memory discipline, Dark Factory loop,
   │                        scope, environments, Jira, standing rules (every session, both agents)
   ├─ setup-pair render ─► ~/.claude/channel-listener/config.json (each rule key, ${derived.*} from rules.py)
   │                        ~/.claude/commands/<start_command>.md
   ├─ kit/lib/kb.py ─────► knowledge rules (what makes the library grow, Engram ids and links)
   └─ hooks ─────────────► the guards enforce what must never depend on a model remembering a rule
```

## Three steps to make the agents follow your rules

1. **Start from your organisation's pack** (optional). `extends: packs/<org>/pair.<org>.yaml` loads the org's
   conventions (Jira card rules, closed statuses, out-of-scope look-alikes, the org rules memory space, guard
   folders) and the org's standing rules. Your file wins on every value.
2. **Write your own standing rules** under `rules.standing`, verbatim, one per entry:
   ```yaml
   rules:
     standing:
       - {rule: "Never merge a PR — I merge.", why: "approve is not merge", by: Jane, date: 2026-09-14}
   ```
   They are ADDED after the pack's rules and printed, numbered, into every session of both agents.
3. **Fill the settings your rules depend on** (all optional; `pair.example.yaml` documents each one):
   who decides when a requester cannot (`team.decision_contact`), where team requests may deploy
   (`environments`), what a Jira card must carry (`jira.card_rules`), where agents never post (`rules.never_post`),
   the Dark Factory loop (`dark_factory`), the reviewer agent (`rules.reviewer`), memory spaces (`engram.*`).

Then `./setup-pair render` on each workspace and restart the agents. `./setup-pair check` confirms the rules
generate, the reviewer agent and Dark Factory skills are installed, and knowledge links are confirmed in Engram.

## See the rules

```bash
python3 kit/lib/rules.py session builder     # exactly what the builder is told at every session start
python3 kit/lib/rules.py session tester
python3 kit/lib/rules.py get jira.card_rules # a setting with its default applied
```

## Prove a rendered pair matches a hand-built one

Any existing, hand-built pair can be checked against the kit: write its `pair.yaml` (outside the kit), render it, and compare
with the hand-built configs is the parity test:

```bash
PAIR_CONFIG=<your pair.yaml> ./setup-pair render --role builder --out /tmp/b
python3 kit/scripts/parity-check.py /tmp/b/config.json <the hand-built config.json> --min 0.8
```

It reports, per rule, the share of the reference's words the rendered rule carries, plus any difference in
channel sources and tuning numbers. A word list is a proxy: read what it says is missing — paths, ticket
examples and rewording show up too.

## Dashboard: one per person

`dashboard.artifact_url` is **your own** page. Each person publishes their own private copy of the kit's dashboard
page and puts that URL in their own `pair.yaml` (docs/SETUP.md, "Your own dashboard"). Never copy another
person's URL: the builder would write your pair's snapshots into their page.

## Identity: measured, confirmed, enforced

`./setup-pair init` measures who this workspace commits and pushes as — git `user.name` / `user.email` as git
resolves them inside a repo under `paths.shared_root` (so scoped `includeIf` identities count) and the ACTIVE `gh`
account — shows them, and asks you to confirm or change each (`identity.*` in pair.yaml). The agents are told to
commit only as that author and push only with that account, and to stop and ask if either differs.
`./setup-pair check` fails on any workspace whose identity drifted. See it: `python3 kit/lib/rules.py identity`.

## Two workspaces, one file, different rules

Both agents read the same `pair.yaml`. Each workspace knows its role from its hostname (`builder.host` /
`tester.host`), and `./setup-pair render` writes only that role's listener rules and start command
(`builder.start_command` / `tester.start_command`, e.g. `/ms` and `/vs`), so each agent is started on its own
workspace with its own command. A standing rule with `for: builder` or `for: tester` goes to that agent only.
