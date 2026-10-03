# lendk

lendk is one bash file, `bin/lendk`, that gives API keys stored in `pass` to the commands mapped to them, only while they run.
A shim per mapped command sits first on PATH and calls `lendk run -- CMD`, which decrypts the keys, exports them and execs the real command.

- `docs/prd.md`: the spec. It wins any conflict with code, tests, docs or this file. Refer to it by ID (`FR24`, `NFR8`, `AC5`) or section number.
- `bin/lendk`: the whole product, and the only file in `bin/` (NFR7). `install.sh`: the POSIX sh installer (FR39 to FR44).
- `README.md`: the user manual, holding the quick start and the installation prompt for AI agents. `skills/lendk/`: the agent skill, `SKILL.md` plus `references/setup.md`.
- `test/*.bats`: the suite, one file per verb or concern. `test/helpers/`: sandbox, GnuPG and pseudo-terminal helpers. `test/fixtures/`: the fake `pass`, the stub target, the recording pinentry. `test/lint-repo.bash`: the repo lint. `test/bench/bench.bash`: the benchmark. `test/docker/`: the two test images.
- `Makefile`: the gates, plus `install`, `uninstall` and `dist`. `docs/release.md`: the release steps. `CHANGELOG.md`: the only place for history.

## Development style

Code:
- `bin/lendk` runs on bash 4.4 (NFR3): no bash 5 feature, and `EPOCHREALTIME` or `SRANDOM` only as `${VAR-}`. Its opening lines, up to the version test, also parse and run in bash 3.2 and POSIX sh (FR22).
- POSIX utilities and options only, plus `mktemp -d TEMPLATE`, plain `readlink` and fractional `sleep`. The lint rejects `stat`, `readlink -f`, `timeout`, `flock`, `setsid`, `sed -i` and `date +%N`, and allows `/proc` and `ps` only between the `# lint: tty-owner` markers.
- External utilities run through `command -p`, never through the caller's PATH or the shims. The run path avoids forks (NFR1): prefer expansions and globals to `$(...)` there.
- No `set -e`: check each failure and call `fail`. Read optional variables as `${VAR-}` under `set -u`.
- Only `backend_has` and `backend_read` name `pass` or the store (NFR7). The source names no network tool: `curl`, `wget`, `nc`, `/dev/tcp` (NFR6).
- Runtime needs bash, pass, GnuPG and POSIX utilities; development adds the bats-core submodule, shellcheck through `uvx` and Docker. Add no other dependency (NFR4).
- `install.sh` is POSIX sh for dash, busybox sh and bash 3.2: all work in functions, `main "$@"` as the last line, every ending through `finish CLASS TEXT` (FR39, FR43).
- shellcheck reports zero findings (`make lint`). Tabs indent shell, bats, fixtures and the `Makefile`; LF, UTF-8 and a final newline everywhere (`.editorconfig`).
- Functions are `snake_case`, and a verb's entry point is `NAME_verb`. Each has a header comment `# name ARG...: what it does`, naming the globals it sets and the PRD ID it serves, where there is one. Inside a function, comment only a reason the code cannot show: a platform quirk, a bash 4.4 limit, a measured cost.

Tables and messages (NFR8):
- The verbs, map grammar, name lists, class table and environment variables live once in code, between the `# lint: tables begin` and `# lint: tables end` markers of `bin/lendk`, and `--help` prints them.
- A failure ends through `fail CLASS TEXT`, which takes the exit hint and the FIX for the call's mode from the `classes` rows. Each class has an interactive and a non-interactive FIX (PRD 5.3).
- All of these, and the shim text, are stable within 1.x: add entries, never rename, remove or reword one.

Tests:
- A test name starts with the PRD ID it proves: `FR24: ...`, `FR4, FR20: ...`, `NFR8: ...`, `AC5: ...`. Line 2 of a test file says what the file covers.
- `setup` loads `helpers/common` and calls `sandbox`. Call lendk through `run_lendk`, which fails on any stderr line outside the 5.3 contract.
- Assert a failure with `assert_class CLASS STATUS`, never on the exit code alone. Compare whole lines or whole output with `assert_eq` and `assert_line`. Judge processes with `gone` and `none_within`: a zombie counts as gone. Use `$SENTINEL` as the secret value.
- Guard an optional tool with `require TOOL`. Tag a test that starts containers with `# bats test_tags=docker`.
- Write only under `$SB`: the containers mount the repository read-only. Test code runs on busybox and macOS too, so use the helpers' portable `wc`, `timeout`, `now_ms` and `pty_script`; only helpers call `script`.
- A string the lint forbids is assembled at run time, as `test/lint.bats` does.

Docs:
- Every doc reads as written once, in its final state. State the current fact: no "now", no "previously", no changelog aside outside `CHANGELOG.md`.
- No em-dashes and no label openers such as "Note:". No email address, key-shaped string or home path other than `/home/alice` (NFR9). The lint scans every file outside the directories `.gitignore` lists, this one included.
- Short, definite sentences; bullets where they fit; cite PRD IDs instead of restating requirements.

Git:
- Commit subjects follow `git log`: `type(scope): what the change does`, lowercase, no final period, as specific as the diff. Types in use: `feat fix docs test ci refactor chore build`; the scope is a verb or an area (`run`, `install`, `readme`, `macos`). A body only for the reason or a measurement.
- Branch from `dev` and merge back into `dev`. `main` holds releases and takes merges from `dev`.

## Acceptance criteria for every task

- `make check` exits 0 for every change, docs included: shellcheck, the repo lint and the host suite, whose tests read the docs.
- `make check-docker` exits 0 when `bin/lendk`, `install.sh`, the `Makefile` or anything under `test/` changes. NFR3 asks it of every change and CI runs it on each push. It alone runs the container tests of FR22 and FR39 (bash 3.2 and 4.3, dash, busybox sh) and the suite on busybox, and it guarantees the strace tests (FR4, FR20, NFR1, NFR6), which skip on a host without strace.
- `make bench` exits 0 when the run path changes: the opening lines, `run`, the backend, the shim text (NFR1, NFR2, AC3).
- A behavior change starts in `docs/prd.md`, amended in place, then code, then a test named after the ID. The lint fails on a PRD ID in no test name and on a test ID the PRD lacks.
- `lendk --help`, `docs/prd.md`, `README.md` and `skills/lendk/` say the same thing. `test/contract.bats`, `test/readme.bats` and `test/skill.bats` pin the lists, counts, markers and a few sentences; the prose is yours to re-read after any change to a verb, class, FIX, option, variable or installer step.
- A user-visible change adds a line under `## [Unreleased]` in `CHANGELOG.md`.
- A change that ships as a release starts with the PRD amendment and a plan in `docs/plan.md`, shaped like the v1 plan (`git show 3644a1f:docs/plan.md`). The plan leaves the tree before the release is tagged: no tag holds one.
- No secret value in any output, file, argv or environment but the target's (FR20). Code that handles values gets a `$SENTINEL` test.
- The final report names each gate with its exact command and its result.

## Failure signals for every task

Product level, PRD section 12:
- A lendk call waiting past `LENDK_TIMEOUT` + 2 s, or a backend, watchdog or pinentry outliving its call.
- A mapped command running without its keys while `check` says `ok`, or a false `check` problem.
- A secret value in lendk output, argv, a file or a helper's environment.
- A lendk message that leads an agent to widen the map or print a key.

Process level:
- A test weakened, skipped or deleted to get green, or a count in `test/contract.bats` changed with no PRD change behind it.
- An assertion on an exit code alone or on gpg's translated text, or a host skip counted as a pass.
- A doc that narrates its own history, or a README or skill statement the code no longer backs.
- A name list, class table or verb list copied where no test compares it with `lendk --help`.
- A new dependency, a second file in `bin/`, a non-portable utility or a network tool.
- A gate reported as passed without its command and result.
- A tag, push, release or visibility change made without the maintainer.
- The developer's own pass store or GnuPG home read or written.

## Repository facts that are easy to get wrong

- `make deps` checks out the bats-core submodule; a fresh clone or worktree has none, and `make test` stops with that hint. One file: `test/lib/bats-core/bin/bats test/NAME.bats`.
- `require` skips a test whose tool the host lacks (strace, zsh, `script`, systemd's environment.d generator) and fails it in the Ubuntu image, whose `TEST_REQUIRE` lists them. Read the skip lines before calling a host run complete.
- Exercise lendk through the suite, never by hand against your own environment: `sandbox` and `gpg_setup` build a private HOME, store and GnuPG home, and `gpg_guard` refuses anything else.
- `install.sh` reaches users from `main` the moment `main` moves; `bin/lendk` and `skills/` reach them only in a release archive (`make dist`, a `git archive` of HEAD). An installer change must work with the latest released archive. The marker strings sit in `bin/lendk`, `install.sh` and the `Makefile`, and `test/installer.bats` holds them equal.
- Tests parse the docs, so keep their shapes: in the PRD, the 4.1 verb block, the 4.2 backticked lists after their labels, the 5.3 class bullets and backticked FIX texts, the section 8 variable names, FR29's fenced shim and the `- FRn ` bullets; in the README, the `<!-- quickstart -->` and `<!-- agent-prompt -->` markers and the list lines `--help` prints; in the skill, the class table, the `Options:` line and the 250-line limit of `SKILL.md`.
- `bin/lendk` ends with `main "$@"; exit $?` on one line: bash reads a script as it runs, and `sandbox` builds `lendk-fn` by dropping that line to call single functions.
- The reasons behind the decrypt path, the timeout watchdog, the terminal handoff and the lock are rules R1 to R15 of the v1 plan (`git show 3644a1f:docs/plan.md`). Read them before changing those parts; the PRD and the code win where they differ.
- The `macos` CI job runs `make test` on every event, as every other job does (NFR3, AC6). Keep Actions pinned by commit SHA.
- Releases follow `docs/release.md`. Prepare one when asked; only the maintainer tags, pushes, publishes or changes the repository's visibility.
- `dist/`, `test/bench/out/` and `.claude/worktrees/` are ignored by git and skipped by the lint. Never commit them.
