# Data Flow — the data-transform view of THIS repo

Companion to `SERVICE-MAP.md`. The service map says *where things live and how
they connect* (structure). This says *what the data is, who owns its truth, and
how it is transformed* (semantics). Model the system as **data nodes** flowing
through **transforms**; tag each transform `pure` (reads only, safe to re-run) or
`effect` (writes state — needs idempotency + a compensation path). Read this
before designing a feature, changing a contract, or moving where truth lives.

## Data nodes (what the data is + who owns its truth)
| Node | Shape / schema | Origin | Authority (system-of-record) | Class / governance |
|---|---|---|---|---|
| `<node>` | `<schema or key shape>` | `<who produces it>` | `<the ONE store/service of record>` | `<public / internal / PII / PHI>`  _(placeholder — replace)_ |

## Transform graph (data node → transform → data node)
Each step is `pure` or `effect`. Effects state idempotency + compensation.
```
<input node>
   │  <transform> (<pure|effect>)  ──►  <output node>
   │  <transform> (effect: idempotent by <key>; undo = <compensation>)  ──►  <node>
```

## Validation rules (where data is checked, and what happens on violation)
| Rule | Locus | Action on violation | Enforced at |
|---|---|---|---|
| `<rule, e.g. field X required & in range>` | `LOCAL` | reject (escalate, don't guess) | `<transform / file:line>` |
| `<rule, e.g. cross-store totals reconcile>` | `GLOBAL` | reconcile against authority | `<reconciler>`  _(placeholder — replace)_ |

> `LOCAL reject` = a transform refuses bad input at its own seam. `GLOBAL reconcile`
> = a discrepancy across nodes is resolved against the authority node, never by the
> first writer to win. Authority rulings live in `DECISIONS.md` — a transform that
> would move authority off a node of record **blocks and escalates**, never "fixes" it.

---
_Add nodes/transforms/rules above this line. Cite a `file:line` or ruling for every
claim; mark unknowns explicitly — never guess origin, authority, or data class._
