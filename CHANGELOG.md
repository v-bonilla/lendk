# Changelog

All notable changes to lendk are documented here. The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and lendk follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Verbs, the one flag, classes, exit-code hints, map grammar, name lists, environment variables and the shim text are stable within 1.x, which only adds entries.

## [Unreleased]

## [1.0.0] - 2026-10-01

### Added

- `lendk run`, `add`, `rm`, `check`, `sync`, `unlock`, and `init` for sh, bash, zsh and systemd environment.d.
- Per-command key injection from pass through PATH shims, with key groups in one map file.
- Fail-fast behavior without a terminal: the `locked` class, `LENDK_PROMPT` and `LENDK_TIMEOUT`.
- A one-line stderr contract, `lendk: CLASS: TEXT. FIX`, with separate fixes for callers without a terminal.
- `make install` and `make uninstall` without root, and `install.sh`, a checksum-verifying installer for the latest release.
- An agent skill, `skills/lendk`, that `install.sh --skill-dir` installs, and a README prompt that has an AI agent install and verify lendk.
- Linux and macOS support; macOS needs bash and GnuPG from Homebrew.

[Unreleased]: https://github.com/v-bonilla/lendk/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/v-bonilla/lendk/releases/tag/v1.0.0
