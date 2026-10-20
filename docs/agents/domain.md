# Domain Docs

How the engineering skills consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root: the domain terms.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in.
- **`CODING_STANDARDS.md`** at the repo root: how code, tests, docs and commits are written.

No doc ranks above another. Tests pin the public interface, which `lendk --help` prints from the Tables module, `src/tables.rs`; ADRs record decisions and their reasons; a conflict between code, tests and docs goes to the maintainer as an issue.

## File structure

This is a single-context repo:

```
/
├── CODING_STANDARDS.md
├── GLOSSARY.md
├── src/
└── docs/
    ├── adr/
    │   ├── 0001-path-shims-not-prefix-command.md
    │   ├── ...
    │   └── 0016-dependencies-admitted-by-rule.md
    ├── agents/
    └── release.md
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR 0007 (no daemon, no value cache), but worth reopening because…_

Reopening a decision starts as an issue for the maintainer.
