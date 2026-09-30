# Changelog

All notable changes to lend are documented here. The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and lend follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Verbs, the one flag, classes, exit-code hints, map grammar, name lists, environment variables and the shim text are stable within 1.x, which only adds entries.

## [Unreleased]

## [1.0.0] - YYYY-MM-DD

### Added

- `lend run`, `add`, `rm`, `check`, `sync`, `unlock`, and `init` for sh, bash, zsh and systemd environment.d.
- Per-command key injection from pass through PATH shims, with key groups in one map file.
- Fail-fast behavior without a terminal: the `locked` class, `LEND_PROMPT` and `LEND_TIMEOUT`.
- A one-line stderr contract, `lend: CLASS: TEXT. FIX`, with separate fixes for callers without a terminal.
- `make install` and `make uninstall` without root.

[Unreleased]: https://github.com/v-bonilla/lend/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/v-bonilla/lend/releases/tag/v1.0.0
