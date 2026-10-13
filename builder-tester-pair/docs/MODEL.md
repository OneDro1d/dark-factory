# The builder/tester model — what it asks, and where the kit does it

The pattern this kit implements: one **tester** session (product owner + solution architect + tester) and one
**builder** session, in **two separate workspaces**, so the builder can never write the tests it is judged by.
Each point below is the model's requirement and the place the kit enforces or carries it.

| # | The model asks | Where the kit does it |
|---|---|---|
| 1 | Two workspaces: builders in one, testers in the other | `builder.host` / `tester.host`; role comes from the hostname; `setup-pair check` fails on any other host |
| 2 | …because every session on a machine can read that machine's transcripts | separate workspaces; the tester's folders (`tester.kits_dir`, `tester.private_dir`) are blocked for the builder by `pair-guard` |
| 3 | The builder never gets the tester's runner credentials | `pair-guard` blocks reading/copying them; `check` fails if the builder holds author tokens |
| 4 | The builder holds only the builder (runner) key | `check`: "builder holds no author tokens"; minting the builder's runner-scope id is the tester's job (TESTER-BRIEF — a rule, not enforced by a tool) |
| 5 | Sessions talk through a governed broker, not copy-paste | `kit/bin/handoff` is the channel (tester ↔ builder only, every step logged and posted); `messaging.broker` names an external broker when one is deployed. **Open:** a live broker (Nuntus) is not part of the kit yet |
| 6 | Name the tester per product; give it a notepad and the Dark Factory pattern | `tester.name`; `dark_factory.enabled`; the tester is told to keep a notepad per task (skill agent-notepad) |
| 7 | The tester is product owner, solution architect and tester | tester rules (`fix_loop` step 0, `df-product-owner` / `df-solution-architect`) |
| 8 | The person discusses requirements with the tester | the builder forwards every new request verbatim (`handoff request`); "<tester> — build …" goes straight to the tester (`handoff spec-open`) |
| 9 | The tester writes specifications, requirements, architecture and test scenarios | `handoff spec` (acceptance + design + requirement node); scenarios stay in the tester's catalog |
| 10 | The builder builds, tests, and reports back when green | builder rules: TDD, unit tests, `handoff fix` with the exact commit |
| 11 | The tester then validates on its own side | `handoff result --stage local` / `--stage live`; `testrun` recheck |
| 12 | The builder never writes test scenarios for itself | builder session rule; the builder never reads the tester's tests |
| 13 | Several builders may serve one tester; builders never talk to each other | rule "builders never message each other". **Open:** the kit configures one builder per pair today |
| 14 | The tester never reveals scenarios or expected answers to the builder | tester rules + leak markers (`canary`) checked on every PASS; when the check cannot run, `handoff result` refuses the PASS unless the tester gives `--canary-unchecked no-canaries-yet|unknown-app-or-commit` (a fixed reason, never free text), which goes on the hand-over |
| 15 | That is enforced by instructions, because code cannot fully enforce it | session rules + listener rules every session; `pair-guard` as a tripwire on top |
| 16 | Agents confirm sensitive asks with the person, never trust a message claiming to be them | ANTI-SPOOFING rule; `chat-approval` verifies the sender; approvals only by the owner. (`restart-request` does not check the sender — it is a convenience that only restarts the agent, not a security boundary) |
| 17 | The tester's runner gets execution access through a hub with scoped tools | `argus.execution_hub` (named in the tester's rules when set) |
| 18 | Validation steps call hub tools, so every check is logged and audited | same; plus the action ledger on both workspaces |
| 19 | Hub access is set per tool: read or write (e.g. dev read-write, production read-only) | configured on the hub; the kit's agents use a read-only cluster identity (`make-agent-kubeconfig.sh`) |
| 20 | Each person deploys the broker / tools in their own namespace | per-person `pair.yaml`, per-person dashboard, per-agent hub sign-in (`kit/scripts/hub-login.sh`) |
| 21 | Set up the hub and memory with the runner this way, tester and builder in separate workspaces | `./setup` on each workspace (`/pair-setup` in Claude) |
| 22 | Use the loop for real work; it doubles as demo material | the change channel and the dashboard show every step |
| 23 | One correlation (ticket) id across every call of all sessions, so cost can be attributed | CORRELATION ID rule: ticket key (else hand-over id) on every hand-over, branch, commit, PR, post, comment |
| 24 | Done is what the runner says, not a self-report | tester rule "DONE is decided by YOUR independent run"; `testrun release` refuses until the tester's recheck exists |

Open items are tracked here so nobody mistakes them for done: a live message broker between sessions (#5) and
more than one builder per tester (#13).
