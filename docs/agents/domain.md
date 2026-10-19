# Domain Docs

How the engineering skills consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`docs/prd.md`**: the spec. It wins any conflict with `GLOSSARY.md`, an ADR, the code, the tests or the other docs. Cite it by ID (`FR24`, `NFR8`, `AC5`) or section number.
- **`GLOSSARY.md`** at the repo root: the glossary.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in.
- **Rules R1 to R15 of the v1 plan** (`git show 3644a1f:docs/plan.md`): the reasons behind the decrypt path, the timeout watchdog, the terminal handoff and the lock. They weigh as ADRs.

If `GLOSSARY.md` or `docs/adr/` doesn't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

This is a single-context repo:

```
/
├── GLOSSARY.md
├── bin/lendk
└── docs/
    ├── prd.md
    └── adr/
        └── 0001-<slug>.md
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_

An ADR never overrides `docs/prd.md`. A decision that changes behavior starts as a PRD amendment.
