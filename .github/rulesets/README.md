# Branch protection as code

`protect-main.json` is the ruleset that guards the default branch. It is kept here
rather than only in the GitHub UI so the protection is reviewable, diffable, and
restorable — a control that exists only as clicks in a settings page is one nobody can
audit and anyone can quietly weaken.

## Applying it

```bash
gh api --method POST repos/<owner>/<repo>/rulesets \
  --input .github/rulesets/protect-main.json
```

To update an existing ruleset, get its id and `PUT` instead:

```bash
gh api repos/<owner>/<repo>/rulesets --jq '.[] | {id, name}'
gh api --method PUT repos/<owner>/<repo>/rulesets/<id> \
  --input .github/rulesets/protect-main.json
```

**Rulesets are free on public repositories and require a paid plan on private ones.**
Applying this to a private repo on a Free plan returns:

```
403 Upgrade to GitHub Pro or make this repository public to enable this feature.
```

That is expected, not a misconfiguration.

## What it does, and the reasoning

| Rule | Why |
|---|---|
| `pull_request`, 0 approvals required | Every change to the default branch arrives as a reviewable diff, but a solo maintainer is not blocked waiting for an approver who does not exist. The audit trail is the point, not the ceremony. |
| `non_fast_forward` | No force-pushes. History rewrites on a published branch break every clone and can silently resurrect or destroy content. |
| `deletion` | The default branch cannot be deleted. |
| `required_status_checks` → `publish-gate` | The gate must actually run. Every gate failure in this repo's history was a check nobody ran, or one that ran and could not catch anything. |
| `strict_required_status_checks_policy` | Branches must be up to date before merging, so the gate result reflects the merged state rather than a stale base. |

### Why the bypass is `pull_request`, not `always`

`bypass_actors` carries one entry: `OrganizationAdmin`, in **`pull_request`** mode.

That means an org admin can merge their own PR without a second approver, but **still
cannot push directly to the default branch**. The gate runs on their changes like
everyone else's.

An `always` bypass would be the obvious alternative and is a trap for a small project:
if the one active maintainer is exempt, the protection applies to approximately none of
the real commits while continuing to report as enabled. That is the same shape as every
control failure this repo documents — a check that is on, and never runs on the traffic
that matters.

The cost of `pull_request` mode is one extra command:

```bash
gh pr create --fill && gh pr merge --auto --squash
```

### Why only one required check

The workflow in `.github/workflows/gate.yml` defines a single job, `publish-gate`, which
runs the self-test and then the gate. The check name that GitHub sees is the **job**
name.

Requiring a context that no job reports — `gate-selftest`, say, which is a *step* inside
that job — would block the branch permanently on a check that can never arrive. If you
split the workflow into separate jobs, add their names here at the same time.
