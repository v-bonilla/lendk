# Coding standards

How lendk's code, tests, docs and commits are written, and the process failures a review flags. Names follow `GLOSSARY.md`; the reasons behind the design are in `docs/adr/`.

## Code

- lendk is the Rust binary below. Runtime needs pass and GnuPG, and `upgrade` alone tar, gzip, `sha256sum` or `shasum`, and curl or wget, found on the caller's PATH without the shim directory. Development adds the bats-core submodule, shellcheck through `uvx`, rustup with the toolchain `rust-toolchain.toml` pins, `cargo-deny` and `cargo-vet` from `make deps`, and Docker for `make check-docker`. A crate joins only through `deny.toml`'s allow list (ADR 0016).
- `install.sh` is POSIX sh for dash, busybox sh and bash 3.2: all work in functions, `main "$@"` as the last line, every ending through `finish CLASS TEXT`. The tests and their helpers run on bash 4.4: no bash 5 feature, and `EPOCHREALTIME` or `SRANDOM` only as `${VAR-}`.
- `install.sh` and the tests use POSIX utilities, with options GNU, BSD and busybox share, plus `mktemp [-d] TEMPLATE`, plain `readlink` and fractional `sleep`; `stat`, `readlink -f`, `flock`, `setsid`, `sed -i` and `date +%N` differ or are missing on macOS or busybox. They run external utilities through `command -p` wherever the caller's PATH or a stub must not decide which one runs.
- No `set -e` in `install.sh` or the tests: check each failure. Read optional variables as `${VAR-}` under `set -u`.
- shellcheck reports zero findings (`make lint`). Tabs indent shell, bats, fixtures and the `Makefile`; LF, UTF-8 and a final newline everywhere (`.editorconfig`).
- Shell functions are `snake_case`. Each has a header comment `# name ARG...: what it does`, naming the globals it sets. Inside a function, comment only a reason the code cannot show: a platform quirk, a bash 4.4 limit, a measured cost.

## Rust

- One Cargo package at the root builds one binary, `lendk`. `rust-toolchain.toml` pins one exact toolchain and `Cargo.toml`'s `rust-version` equals it; a distro's `rustc` is unsupported. `Cargo.lock` is committed, every build runs `--locked`, and an update is one `cargo update -p NAME` in a commit of its own, with its audits. No `cargo vendor`, no `cargo auditable`.
- Direct dependencies are the crates ADR 0016 admits, each with `default-features = false` and the features it uses listed. No convenience crate (`clap`, `anyhow`, `thiserror`, `serde`, `log`, `rpassword`, `termios`) and no wrapper over an OS call (`rustix`, `nix`, `linux-keyutils`, `security-framework`, `secrecy`, `memsec`, `region`, `secrets`). Dev-dependencies follow the same rule.
- `deny.toml` names every crate in the tree in its allow list, and `supply-chain/` shows each one meeting `safe-to-deploy`. Only the maintainer runs `cargo vet certify`.
- `#![deny(unsafe_code)]` holds crate-wide; the System calls module alone is allowed `unsafe`, and each block carries a `// SAFETY:` comment (`undocumented_unsafe_blocks`).
- lendk declares `#![no_main]` with a C `main(argc, argv, envp)`, and reads its arguments and environment from those. `clippy.toml` bans `std::env`'s readers and setters and `Command::{env, envs}` outside the helpers module, which alone allows `clippy::disallowed_methods`, calls `env_clear()` and sets only its allowlist. It bans the socket types of `std::net` and `std::os::unix::net` everywhere.
- Plaintext lives in one `Plaintext` buffer lendk owns: no `Clone`, no `Display`, a `Debug` that shows none of the bytes, sized once before the first decrypt and never reallocated in place, kept out of swap with `mlock`, marked `MADV_DONTDUMP` on Linux, and zeroed on drop and on every exit path. It is read through `read(2)`, never through std's buffered `Stdin`, `Command::output()` or a crate that returns a `String`. Plaintext enters a library only as the copy that library's API requires, made from lendk's buffer, zeroed on drop, and dropped as soon as the call returns.
- The source names `curl` and `wget` only between the `// lint: network begin` and `// lint: network end` markers, which hold the functions `upgrade` downloads through (ADR 0013). Only the Pass reader module, `src/pass.rs`, runs pass.
- `cargo fmt` formats the source, and clippy reports zero findings at `-D warnings` (`make lint`).

## Tables and messages

- The verbs, map grammar, name lists, class table and environment variables live once in code, in the Tables module, `src/tables.rs`, and `--help` prints them. `test/contract.bats` holds `--help` byte-identical to the frozen 1.x lendk's, `test/fixtures/lendk-1.x`, until the 2.x list replaces the 1.x one.
- A failure ends through the Failure module, `src/failure.rs`, which takes the exit hint and the FIX for the call's mode from the class rows. Each class has an interactive and a non-interactive FIX, and the non-interactive one hands the step to the user or points to `lendk --help` (ADR 0012).
- All of these, and the shim text, are stable within 1.x: add entries, never rename or remove one, and change a description only to keep it true (ADR 0011). The change that adds an entry also appends it to the frozen 1.x list in `test/frozen/`, and the release that ships it raises the minor version.

## Tests

- A test name states the behavior it proves, in the glossary's terms. Line 2 of a test file says what the file covers.
- `setup` loads `helpers/common` and calls `sandbox`. Call lendk through `run_lendk`, which fails on any stderr line but a `lendk: CLASS: TEXT. FIX` or `lendk: notice: TEXT.` line, and on a non-interactive line that suggests a forbidden action.
- Assert a failure with `assert_class CLASS STATUS`, which checks the `lendk: CLASS:` line with the status, never the exit code alone. Compare whole lines or whole output with `assert_eq` and `assert_line`. Judge processes by state with `gone` and `none_within`: a zombie counts as gone. Use `$SENTINEL` as the value.
- Guard an optional tool with `require TOOL`. Tag a test that starts containers with `# bats test_tags=docker`.
- Call lendk as `$LENDK`, which names the release binary `make build` writes unless the environment names another file by its absolute path. A behavior no verb reaches is a `cargo test` case in its module, never a test that calls into lendk's internals.
- Write only under `$SB`: the containers mount the repository read-only. Test code runs on busybox and macOS too, so use the helpers' portable `wc`, `timeout`, `now_ms` and `pty_script`; only helpers call `script`.
- A string the lint forbids is assembled at run time, as `test/lint.bats` does.

## Docs

- Files that GitHub or the skills look up by name sit uppercase at the root: `README.md`, `CHANGELOG.md`, `SECURITY.md`, `LICENSE`, `GLOSSARY.md`, `CODING_STANDARDS.md`. Every other doc is lowercase kebab-case under `docs/`. An ADR is `docs/adr/NNNN-kebab-slug.md`, numbered from 0001 and never renumbered.
- The README is the user manual. The skill's `SKILL.md` teaches the mental model, every verb, the class table with what to do for each class, the agent rules, answers to common questions and troubleshooting with `lendk check`; its `references/setup.md` covers setup, PATH, upgrade and uninstall.
- Every doc reads as written once, in its final state. State the current fact: no "now", no "previously", no changelog aside outside `CHANGELOG.md`.
- No em-dashes and no label openers such as "Note:". No email address, key-shaped string or home path other than `/home/alice`; `supply-chain/imports.lock` alone may hold email addresses, as cargo-vet's copy of third-party audit records. The lint scans every file outside the directories `.gitignore` lists, this one included.
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
- A crate outside `deny.toml`'s allow list, or an exemption added to `supply-chain/`.
- A non-portable utility in `install.sh` or the tests, or a network tool outside the network region.
- A gate reported as passed without its command and result.
- A tag, push, release or visibility change made without the maintainer.
- The developer's own pass store or GnuPG home read or written.
