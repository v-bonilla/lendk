# The CLASS line is the contract, and 1.x only adds to it

Callers, agents above all, need one stable signal for what went wrong. Before exec, lendk writes only `lendk: CLASS: TEXT. FIX` and `lendk: notice: TEXT.` lines to stderr, and a notice reports a change or a risk, never a failure. The CLASS is the contract; exit codes are hints. They cannot be unique: after exec the target's own exit codes reach the caller unchanged, CPython exits 120 when flushing stdout fails, and docker, coreutils `env` and `timeout`, and `git bisect run` give 125 to 127 their own meanings. A nested shim's line also reaches the caller through the outer command's stderr, with whatever exit status the outer command chooses. Because callers, the README, the agent skill and its copies match on these names and texts, the public interface is fixed within 1.x: the verbs, `--force`, the classes and their exit hints, the FIX texts, the map grammar, the name lists, the environment variables and the shim text only grow. A release that adds to them raises the minor version.

## Considered Options

- Exit codes as the contract: a caller cannot tell lendk's 125 from the target's, CPython's 120 or docker's 125.
- Renaming or removing a verb, class, FIX, list word or variable within 1.x: every caller and every skill copy that matches on it breaks silently. `lendk upgrade` leaves a skill copy as it is, so a newer lendk must keep every name an older copy teaches.

## Consequences

- A description may still change to stay true; names, exit hints, FIX texts and the shim text may not.
- The tables live once, between the `# lint: tables begin` and `# lint: tables end` markers of `bin/lendk`, and `lendk --help` prints them.
- `test/frozen/` holds every 1.x verb line, name-list word, class with its exit hint, FIX text and variable name, and the shim text. `test/contract.bats` fails when `lendk --help`, or the shim `lendk sync` writes, lacks one of them. A release that adds to the tables appends to `test/frozen/` in the same change.
- When the kernel refuses a target that passed lendk's checks, bash's own lines come first, and the `exec` line still ends stderr.
