# lendk

lendk is one bash file, `bin/lendk`, that gives API keys stored in `pass` to the commands mapped to them, only while they run.
A shim per mapped command sits first on PATH and calls `lendk run -- CMD`, which decrypts the keys, exports them and execs the real command.

- `bin/lendk`: the whole product, and the only file in `bin/`. Its tables region defines the public interface once, and `lendk --help` prints it. `install.sh`: the POSIX sh installer.
- `CODING_STANDARDS.md`: how code, tests, docs and commits are written, and the process failures a review flags. Read it before writing code in `bin/lendk`, `install.sh` or `test/`, a doc, or a commit.
- `GLOSSARY.md`: the domain terms. `docs/adr/`: the decisions and their reasons. No doc ranks above another: tests pin the public interface, and a conflict between code, tests and docs goes to the maintainer as an issue.
- `README.md`: the user manual, holding the quick start and the installation prompt for AI agents. `skills/lendk/`: the agent skill, `SKILL.md` plus `references/setup.md`.
- `test/*.bats`: the suite, one file per verb or concern. `test/frozen/`: the frozen 1.x verb synopses, name lists, classes with exit hints, FIX texts, variable names and shim text, which `test/contract.bats` checks `--help` against. `test/helpers/`: sandbox, GnuPG and pseudo-terminal helpers. `test/fixtures/`: the fake `pass`, the stub target, the recording pinentry. `test/lint-repo.bash`: the repo lint. `test/bench/bench.bash`: the benchmark. `test/docker/`: the two test images.
- `Makefile`: the gates, plus `install`, `uninstall` and `dist`. `docs/release.md`: the release steps. `CHANGELOG.md`: the only place for history.

## Acceptance criteria for every task

- `make check` exits 0 for every change, docs included: shellcheck, the repo lint and the host suite, whose tests read the docs.
- `make check-docker` exits 0 when `bin/lendk`, `install.sh`, the `Makefile` or anything under `test/` changes, and CI runs it on each push. It alone runs the container tests (lendk's opening lines under bash 3.2 and 4.3, the installer under bash 3.2, dash and busybox sh) and the suite in bash 4.4 on busybox. Its Ubuntu 24.04 run guarantees every test a host may skip, such as real GnuPG in both of pass's branches and strace.
- `make bench` exits 0 on the development host when the run path changes: the opening lines, `run`, the backend, the shim text.
- A behavior change, to what `bin/lendk` or `install.sh` does or to what `--help` or the README promises, starts as an issue and lands as code with a test. Any other change goes straight to `dev`. `docs/agents/issue-tracker.md` says which issue to open and how it closes.
- A change that ships as a release starts with a spec issue, which holds its plan, and its tickets.
- `lendk --help`, `README.md` and `skills/lendk/` say the same thing. `test/contract.bats`, `test/readme.bats` and `test/skill.bats` pin the lists, counts, markers and a few sentences; the prose is yours to re-read after any change to a verb, class, FIX, option, variable or installer step.
- A user-visible change adds a line under `## [Unreleased]` in `CHANGELOG.md`.
- The final report names each gate with its exact command and its result.

## Safety rules

- A value reaches the target's environment and nothing else: no output, file, argv or other process's environment. Code that handles values gets a `$SENTINEL` test.
- lendk reaches the network only in a `lendk upgrade` the user runs (ADR 0013).
- Exercise lendk through the suite, so the developer's own pass store and GnuPG home stay untouched: `sandbox` and `gpg_setup` build a private HOME, store and GnuPG home, and `gpg_guard` refuses anything else. `run_lendk` refuses `upgrade` on the working tree's `bin/lendk`, and every sandbox holds `curl` and `wget` stubs that fail, so no test replaces the source or reaches the network.
- Releases follow `docs/release.md`. Prepare one when asked; only the maintainer tags, pushes, publishes or changes the repository's visibility.

## Failure signals for every task

Each of these is a lendk failure, and the next release fixes it first:

- A lendk call waiting past `LENDK_TIMEOUT` + 2 s, or a backend, download tool, watchdog or pinentry outliving its call.
- A mapped command running without its keys while `check` says `ok`, or a false `check` problem.
- A secret value in lendk output, argv, a file or a helper's environment.
- A lendk message that leads an agent to widen the map, print a key or upgrade lendk unasked.
- `lendk upgrade` leaving a lendk that does not run, a partly written file, or a changed login file, map, store or skill copy.
- lendk using the network in any call but a `lendk upgrade` the user ran.

## Repository facts that are easy to get wrong

- `make deps` checks out the bats-core submodule; a fresh clone or worktree has none, and `make test` stops with that hint. One file: `test/lib/bats-core/bin/bats test/NAME.bats`.
- `require` skips a test whose tool the host lacks (strace, zsh, `script`, systemd's environment.d generator) and fails it in the Ubuntu image, whose `TEST_REQUIRE` lists them. Read the skip lines before calling a host run complete.
- `install.sh` reaches users from `main` the moment `main` moves; `bin/lendk` and `skills/` reach them only in a release archive (`make dist`, a `git archive` of HEAD), which `install.sh` and `lendk upgrade` both read from `releases/latest/download/`. An installer change must work with the latest released archive. The marker strings sit in `bin/lendk`, `install.sh` and the `Makefile`, and `test/installer.bats` holds them equal.
- Tests parse the README and the skill, so keep their shapes: in the README, the `<!-- quickstart -->` and `<!-- agent-prompt -->` markers and the list lines `--help` prints; in the skill, the class table, the `Options:` line and the 250-line limit of `SKILL.md`.
- `bin/lendk` ends with `main "$@"; exit $?` on one line: bash reads a script as it runs, and `sandbox` builds `lendk-fn` by dropping that line to call single functions.
- The reasons behind the decrypt path, the timeout watchdog and the terminal handoff are ADRs 0004 to 0006 in `docs/adr/`, and those behind the write lock are the comments on `take_lock` and `break_lock`. Read them before changing those parts.
- `dist/`, `test/bench/out/` and `.claude/worktrees/` are ignored by git and skipped by the lint. Never commit them.

## Agent skills

### Issue tracker

Issues live in the GitHub Issues of `v-bonilla/lendk`, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, each label named after its role: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` at the repository root, and `docs/adr/`. See `docs/agents/domain.md`.
