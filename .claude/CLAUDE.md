# lendk

lendk is one Rust binary that gives API keys stored in `pass` to the commands mapped to them, only while they run.
A shim per mapped command sits first on PATH and calls `lendk run -- CMD`, which decrypts the keys, exports them and execs the real command.

- `src/`: the whole product, one Cargo package at the root building one binary `lendk` (`tables.rs` defines the public interface once and `lendk --help` prints it, `failure.rs` the class line, `sys.rs` the one `unsafe` module), with `Cargo.toml` and the committed `Cargo.lock`, `rust-toolchain.toml` (the one pinned toolchain), `clippy.toml` (the environment and socket bans), `deny.toml` (the closed crate allow list) and `supply-chain/` (cargo-vet), all under ADR 0016. `install.sh`: the POSIX sh installer.
- `CODING_STANDARDS.md`: how code, tests, docs and commits are written, and the process failures a review flags. Read it before writing code in `src/`, `install.sh` or `test/`, a doc, or a commit.
- `GLOSSARY.md`: the domain terms. `docs/adr/`: the decisions and their reasons. No doc ranks above another: tests pin the public interface, and a conflict between code, tests and docs goes to the maintainer as an issue.
- `README.md`: the user manual, holding the quick start and the installation prompt for AI agents. `skills/lendk/`: the agent skill, `SKILL.md` plus `references/setup.md`.
- `test/*.bats`: the suite, one file per verb or concern. `test/frozen/`: the frozen 1.x verb synopses, name lists, classes with exit hints, FIX texts, variable names and shim text, which `test/contract.bats` checks `--help` against. `test/helpers/`: sandbox, GnuPG and pseudo-terminal helpers. `test/fixtures/`: the fake `pass`, the stub target, the recording pinentry, and `lendk-1.x`, the frozen 1.x lendk that serves the installer's 1.x path. `test/lint-repo.bash`: the repo lint. `test/bench/bench.bash`: the benchmark. `test/docker/`: the two test images.
- `Makefile`: the gates, plus `build`, `install` (a `cargo build --release --locked`, then a rename into `PREFIX/bin`), `uninstall` and `dist`. `docs/release.md`: the release steps. `CHANGELOG.md`: the only place for history.

## Acceptance criteria for every task

- `make check` exits 0 for every change, docs included: shellcheck, the repo lint, `cargo fmt --check`, clippy at `-D warnings`, the release build, `cargo test`, the host suite against that build, whose tests read the docs, `cargo deny --frozen check -D warnings bans licenses sources` and `cargo vet --locked --frozen`. It runs offline after `make deps`.
- `make check-docker` exits 0 when `src/`, `install.sh`, the `Makefile` or anything under `test/` changes, and CI runs it on each push. It alone runs the container tests (the installer under bash 3.2, dash and busybox sh) and the suite against the release binary in bash 4.4 on busybox. Its Ubuntu 24.04 run guarantees every test a host may skip, such as real GnuPG in both of pass's branches, strace and the from-source tests, which build with the host's pinned toolchain and fetched crates mounted read-only.
- `make bench` exits 0 on the development host when the run path changes: `main`'s opening, `run`, the backend, the shim text. With no `LENDK` it measures the release binary.
- A behavior change, to what lendk or `install.sh` does or to what `--help` or the README promises, starts as an issue and lands as code with a test. Any other change goes straight to `dev`. `docs/agents/issue-tracker.md` says which issue to open and how it closes.
- A change that ships as a release starts with a spec issue, which holds its plan, and its tickets.
- `lendk --help`, `README.md` and `skills/lendk/` say the same thing. `test/contract.bats`, `test/readme.bats` and `test/skill.bats` pin the lists, counts, markers and a few sentences; the prose is yours to re-read after any change to a verb, class, FIX, option, variable or installer step.
- A user-visible change adds a line under `## [Unreleased]` in `CHANGELOG.md`.
- The final report names each gate with its exact command and its result.

## Safety rules

- A value reaches the target's environment and nothing else: no output, file, argv or other process's environment. Code that handles values gets a `$SENTINEL` test.
- lendk reaches the network only in a `lendk upgrade` the user runs (ADR 0013).
- Exercise lendk through the suite, so the developer's own pass store and GnuPG home stay untouched: `sandbox` and `gpg_setup` build a private HOME, store and GnuPG home, and `gpg_guard` refuses anything else. `run_lendk` refuses `upgrade` on the lendk under test and on any file in the working tree, and every sandbox holds `curl` and `wget` stubs that fail, so no test replaces the source or reaches the network.
- Releases follow `docs/release.md`. Prepare one when asked; only the maintainer tags, pushes, publishes or changes the repository's visibility.

## Failure signals for every task

Each of these is a lendk failure, and the next release fixes it first:

- A lendk call waiting past `LENDK_TIMEOUT` + 2 s, or a backend, download tool, watchdog or pinentry outliving its call.
- A mapped command running without its keys while `check` says `ok`, or a false `check` problem.
- A secret value in lendk output, argv, a file or a helper's environment.
- A lendk message that leads an agent to widen the map, print a key or upgrade lendk unasked.
- `lendk upgrade` leaving a lendk that does not run, a partly written file, or a changed login file, map, store or skill copy.
- lendk using the network in any call but a `lendk upgrade` the user ran.
- A release binary carrying a crate with a RustSec vulnerability advisory that `deny.toml` does not ignore.

## Repository facts that are easy to get wrong

- `make deps` checks out the bats-core submodule, runs `cargo fetch --locked` and installs `cargo-deny` and `cargo-vet` at the Makefile's exact versions into `.tools/`; a fresh clone or worktree has none, and `make test` stops with that hint. One file: `test/lib/bats-core/bin/bats test/NAME.bats` after `make build`; the suite runs the release binary unless `LENDK` names another file by its absolute path.
- On Linux the Makefile builds for the host architecture's static musl target, with `rust-lld` and self-contained musl, so one binary runs on the host and in both test images. rustup installs the pinned toolchain and its musl targets from `rust-toolchain.toml`.
- `require` skips a test whose tool the host lacks (strace, zsh, `script`, systemd's environment.d generator) and fails it in the Ubuntu image, whose `TEST_REQUIRE` lists them. Read the skip lines before calling a host run complete.
- `install.sh` reaches users from `main` the moment `main` moves; lendk and `skills/` reach them only in a release archive, which `install.sh` and `lendk upgrade` both read from `releases/latest/download/`. An installer change must work with the latest released archive, 1.1.0's `lendk.tar.gz`, until the binary's release. The binary's marker sits in `src/upgrade.rs`, `install.sh` and the `Makefile`, 1.x's in `test/fixtures/lendk-1.x`, `install.sh` and the `Makefile`, and `test/installer.bats` holds each equal.
- Tests parse the README and the skill, so keep their shapes: in the README, the `<!-- quickstart -->` and `<!-- agent-prompt -->` markers and the list lines `--help` prints; in the skill, the class table, the `Options:` line and the 250-line limit of `SKILL.md`.
- The reasons behind the decrypt path, the timeout bound and its watchdog, and values in memory are ADRs 0004 to 0006 in `docs/adr/`, and those behind the write lock are the comments on `Lock::take`, `Lock::wait` and `Lock::break_lock` in `src/shims.rs`. Read them before changing those parts.
- `dist/`, `target/`, `.tools/`, `test/bench/out/` and `.claude/worktrees/` are ignored by git and skipped by the lint. Never commit them.

## Agent skills

### Issue tracker

Issues live in the GitHub Issues of `v-bonilla/lendk`, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, each label named after its role: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` at the repository root, and `docs/adr/`. See `docs/agents/domain.md`.
