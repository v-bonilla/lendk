# Guarded commands need `--force`; reserved commands and denied names are refused

Per-command least privilege fails quietly when the mapped command runs other programs: a mapped shell, interpreter, launcher, package tool or agent CLI hands its keys to everything it runs. So `lendk add` maps a guarded command only with `--force`, and then prints a notice that names the risk; widening a command's reach is a deliberate act, never a side effect. Two kinds of name are refused outright. A reserved command belongs to lendk's own runtime (lendk, bash, pass and GnuPG's programs): a shim named `bash` would sit in front of the bash that lendk's own first line finds on PATH, and keys mapped to pass or gpg would reach the backend and any gpg-agent it starts ([ADR 0006](0006-values-only-in-memory.md)). A denied name can never be a key, because it steers lendk, pass, gpg, the shell or the loader (`LENDK_` in any case, `PASSWORD_STORE_`, `GNUPG`, `BASH`, `LD_`), reaches the backend (a key exported to a target that runs a nested shim would reach that call's backend through its allowlist), or names a variable that bash rejects or keeps for itself (`UID`, `RANDOM`, `SECONDS`).

## Considered Options

- Refusing guarded commands outright: mapping an agent CLI such as `claude` or `codex` to a group of keys is a main use, and the human may choose it.
- Mapping them silently: the keys would reach every program the command starts, with no sign that they do.

## Consequences

- `lendk add` enforces the guard. A guarded command that a human writes into the map by hand gets its shim from `lendk sync` like any other mapped command.
- The non-interactive FIX of `guarded` sends an agent to the human, so an agent never adds `--force` by itself: see [ADR 0012](0012-agent-fixes-never-widen-access.md).
- The reserved commands, the denied prefixes and names, and the five guarded lists live once, in the tables of `bin/lendk`, and `lendk --help` prints them.
