# Changelog

All notable changes to lendk are documented here. The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and lendk follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Verbs, the one flag, classes, exit-code hints, map grammar, name lists, environment variables and the shim text are stable within 1.x, which only adds entries.

## [Unreleased]

### Changed

- The README's quick start and its Installation section show one install command, which also copies the agent skill to `~/.claude/skills/lendk` with `--skill-dir`.

## [1.1.0] - 2026-10-04

### Added

- `lendk upgrade`: replaces lendk with the latest release, checked against its checksum, by a rename, then runs `lendk sync`. It leaves the map, the store, PATH setup and a skill copy as they are.
- The `upgrade` class, for a failed `lendk upgrade`; lendk's own file is unchanged.
- `LENDK_INSTALL_BASE_URL` is read by lendk, in `lendk upgrade`, as `install.sh` reads it.

### Changed

- lendk uses the network in `lendk upgrade` only, when the user runs it; no other verb does.
- `LENDK_TIMEOUT` also bounds the fetch of `lendk upgrade`.
- `install.sh` points macOS users without Homebrew to brew.sh.

## [1.0.0] - 2026-10-01

### Added

- `lendk run`, `add`, `rm`, `check`, `sync`, `unlock`, and `init` for sh, bash, zsh and systemd environment.d.
- Per-command key injection from pass through PATH shims, with key groups in one map file.
- Fail-fast behavior without a terminal: the `locked` class, `LENDK_PROMPT` and `LENDK_TIMEOUT`.
- A one-line stderr contract, `lendk: CLASS: TEXT. FIX`, with separate fixes for callers without a terminal.
- `make install` and `make uninstall` without root, and `install.sh`, a checksum-verifying installer for the latest release.
- An agent skill, `skills/lendk`, that `install.sh --skill-dir` installs, and a README prompt that has an AI agent install and verify lendk.
- Linux and macOS support; macOS needs bash and GnuPG from Homebrew.

[Unreleased]: https://github.com/v-bonilla/lendk/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/v-bonilla/lendk/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/v-bonilla/lendk/releases/tag/v1.0.0
