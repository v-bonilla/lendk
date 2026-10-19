# Coding standards

How lendk's code, tests, docs and commits are written, and the process failures a review flags. Names follow `GLOSSARY.md`; the reasons behind the design are in `docs/adr/`.

## Code

- `bin/lendk` runs on bash 4.4: no bash 5 feature, and `EPOCHREALTIME` or `SRANDOM` only as `${VAR-}`. Its opening lines, up to the version test, also parse and run in bash 3.2 and POSIX sh, so an older shell gets `unsupported` (ADR 0010).
- POSIX utilities and options only, plus `mktemp [-d] TEMPLATE`, plain `readlink` and fractional `sleep`. `upgrade` alone, and no other verb, also uses tar, gzip, `sha256sum` or `shasum`, and curl or wget, with options GNU, BSD and busybox share. The lint rejects `stat`, `readlink -f`, `timeout`, `flock`, `setsid`, `sed -i` and `date +%N`, and allows `/proc` and `ps` only between the `# lint: tty-owner` markers.
- External utilities run through `command -p`, never through the caller's PATH or the shims. `upgrade` alone finds its tools on the caller's PATH without the shim directory. The run path avoids forks: prefer expansions and globals to `$(...)` there.
- No `set -e`: check each failure and call `fail`. Read optional variables as `${VAR-}` under `set -u`.
- Only `backend_has` and `backend_read` name `pass` or the store. The source names `curl` and `wget` only between the `# lint: network begin` and `# lint: network end` markers, which hold the one function `upgrade` downloads through, and never `nc` or `/dev/tcp` (ADR 0013).
- Runtime needs bash, pass, GnuPG and POSIX utilities, and `upgrade` alone the tools above. Development adds the bats-core submodule, shellcheck through `uvx`, and Docker for `make check-docker`. Add no other dependency.
- `install.sh` is POSIX sh for dash, busybox sh and bash 3.2: all work in functions, `main "$@"` as the last line, every ending through `finish CLASS TEXT`.
- shellcheck reports zero findings (`make lint`). Tabs indent shell, bats, fixtures and the `Makefile`; LF, UTF-8 and a final newline everywhere (`.editorconfig`).
- Functions are `snake_case`, and a verb's entry point is `NAME_verb`. Each has a header comment `# name ARG...: what it does`, naming the globals it sets. Inside a function, comment only a reason the code cannot show: a platform quirk, a bash 4.4 limit, a measured cost.

## Tables and messages

- The verbs, map grammar, name lists, class table and environment variables live once in code, between the `# lint: tables begin` and `# lint: tables end` markers of `bin/lendk`, and `--help` prints them.
- A failure ends through `fail CLASS TEXT`, which takes the exit hint and the FIX for the call's mode from the `classes` rows. Each class has an interactive and a non-interactive FIX, and the non-interactive one hands the step to the user or points to `lendk --help` (ADR 0012).
- All of these, and the shim text, are stable within 1.x: add entries, never rename or remove one, and change a description only to keep it true (ADR 0011). The change that adds an entry also appends it to the frozen 1.x list in `test/frozen/` and raises the counts `test/contract.bats` checks, and the release that ships it raises the minor version.

## Tests

- A test name states the behavior it proves, in the glossary's terms. Line 2 of a test file says what the file covers.
- `setup` loads `helpers/common` and calls `sandbox`. Call lendk through `run_lendk`, which fails on any stderr line but a `lendk: CLASS: TEXT. FIX` or `lendk: notice: TEXT.` line, and on a non-interactive line that suggests a forbidden action.
- Assert a failure with `assert_class CLASS STATUS`, which checks the `lendk: CLASS:` line with the status, never the exit code alone. Compare whole lines or whole output with `assert_eq` and `assert_line`. Judge processes by state with `gone` and `none_within`: a zombie counts as gone. Use `$SENTINEL` as the secret value.
- Guard an optional tool with `require TOOL`. Tag a test that starts containers with `# bats test_tags=docker`.
- Write only under `$SB`: the containers mount the repository read-only. Test code runs on busybox and macOS too, so use the helpers' portable `wc`, `timeout`, `now_ms` and `pty_script`; only helpers call `script`.
- A string the lint forbids is assembled at run time, as `test/lint.bats` does.

## Docs

- Files that GitHub or the skills look up by name sit uppercase at the root: `README.md`, `CHANGELOG.md`, `SECURITY.md`, `LICENSE`, `GLOSSARY.md`, `CODING_STANDARDS.md`. Every other doc is lowercase kebab-case under `docs/`. An ADR is `docs/adr/NNNN-kebab-slug.md`, numbered from 0001 and never renumbered.
- The README is the user manual. The skill's `SKILL.md` teaches the mental model, every verb, the class table with what to do for each class, the agent rules, answers to common questions and troubleshooting with `lendk check`; its `references/setup.md` covers setup, PATH, upgrade and uninstall.
- Every doc reads as written once, in its final state. State the current fact: no "now", no "previously", no changelog aside outside `CHANGELOG.md`.
- No em-dashes and no label openers such as "Note:". No email address, key-shaped string or home path other than `/home/alice`. The lint scans every file outside the directories `.gitignore` lists, this one included.
- Short, definite sentences; bullets where they fit; the glossary's terms in any text you write or edit. Point to the test, ADR or `--help` line that holds a fact instead of restating it.

## Git

- Commit subjects follow `git log`: `type(scope): what the change does`, lowercase, no final period, as specific as the diff. Types in use: `feat fix docs test ci refactor chore build`; the scope is a verb or an area (`run`, `install`, `readme`, `macos`). A body only for the reason or a measurement.
- Branch from `dev` and merge back into `dev`. `main` holds releases and takes merges from `dev`. A spec may run on an integration branch cut from `dev`, with one branch per ticket merged into it, until the integration branch merges into `dev`.

## Failure signals

A review flags each of these:

- A test weakened, skipped or deleted to get green, or an entry removed or renamed in the frozen 1.x list.
- An assertion on an exit code alone or on gpg's translated text, or a host skip counted as a pass.
- A doc that narrates its own history, or a README or skill statement the code no longer backs.
- A name list, class table or verb list copied where no test compares it with `lendk --help`.
- A new dependency, a second file in `bin/`, a non-portable utility, or a network tool outside the network region.
- A gate reported as passed without its command and result.
- A tag, push, release or visibility change made without the maintainer.
- The developer's own pass store or GnuPG home read or written.
