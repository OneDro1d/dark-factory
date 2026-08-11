## What failure does this prevent?

<!--
The one rule that matters here. "Cleaner", "more consistent" and "best practice" are not
reasons — a rule that cannot name its failure is one nobody will keep under pressure.

If this is a docs or typo fix, say so and delete the rest of this template.
-->

## Content boundary

<!-- See CONTENT-BOUNDARY.md. Nothing here may name a client, cluster, hostname, ticket
     or person. The distinction that catches people out is landmarks vs vocabulary:
     `HIPAA` and `Schematron` are public standards and belong; a real cluster ARN does not. -->

- [ ] No client, cluster, hostname, ticket id, or personal identifier added
- [ ] If I added anything to `boot-kit/scripts/`, I did **not** put real landmark patterns
      in a committed file — they belong in `landmarks.conf`, which is gitignored

## Gate

- [ ] `bash boot-kit/scripts/gate-selftest.sh` passes (7/7 classes fire, baseline clean)
- [ ] If I added or changed a pattern, I added its **canary** to the landmark config —
      a pattern with no canary cannot be proven to fire

<!--
MAINTAINERS — READ BEFORE MERGING

CI runs the gate against `landmarks.example.conf`, whose patterns match fictional
companies, because the real `landmarks.conf` is gitignored (it IS the list of nouns that
must not be published).

So a green check proves the gate is well-formed and that no class has gone inert.
It does NOT prove this branch is free of real landmarks.

Before merging anything that touches docs, skills, reference or boot-kit, run locally
with the real config present:

    bash boot-kit/scripts/publish-gate.sh --history

A check that looks stronger than it is is worse than no check — which is why this note is
here rather than in someone's head.
-->
