# Service Map (compressed)

One line per component. For detail, open that service's `CLAUDE.md`. For message contracts, see the shared-models `CLAUDE.md`. Verify against code before acting; flag drift to knowledge-keeper.

## Services
| Service | Lang | Role | In → Out |
|---|---|---|---|
| `<service>` | `<lang>` | `<one-line role>` | `<input>` → `<output / routing key / store key>`  _(placeholder — replace)_ |

## Cross-service contracts that silently break if drifted
- `<object-store key shape>`: producer ↔ consumer.  _(placeholder — replace)_
- `<record field shape>`: producer ↔ consumer.
- Routing keys: every published key must match the shared-models contract index.

## Infra & cross-cutting (fill in for this repo)
- **Transport**: `<queue / sidecar / library model>`.
- **Stores**: `<primary DB (source of truth)>`, `<secondary stores>`, `<object store>`.
- **DB access rule**: `<via the approved data path — never direct mutating SQL>`.

---
_Add components above this line. Cite a `file:line` or ruling for every claim; verify against code before acting._
