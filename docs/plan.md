# lend implementation plan

This plan takes lend from an empty repository to a v1.0.0 release that meets `docs/prd.md`. Stages `M1` to `M10` run in order; each fits one implementation pass and is checked independently against its done-criteria. The PRD wins any conflict.

Every stage is done only when its listed test files pass, all earlier tests still pass, `make check` passes (zero shellcheck findings, shfmt clean, repo lint clean), and each FR test is named `FRn: ...`.

## 1. Repository layout

| Path | Purpose |
|---|---|
| `bin/lend` | The tool: one executable bash file (NFR7) with every verb, `init` code, `--help` and the version. |
| `Makefile` | `deps`, `lint`, `test`, `test-mock`, `test-net`, `test-bash44`, `bench`, `check`, `install`, `uninstall`. |
| `README.md` | Quick start, reference, security model, FR33 topics, "For AI agents". |
| `CHANGELOG.md` | Keep a Changelog 1.1.0, SemVer. |
| `LICENSE` | MIT, `v-bonilla`. |
| `docs/prd.md`, `docs/plan.md`, `docs/release.md` | Requirements, this plan, release checklist. |
| `.editorconfig` | UTF-8, LF, final newline; tabs for shell, bats, Makefile; 2 spaces for Markdown, YAML; shfmt keys `binary_next_line`, `switch_case_indent`. |
| `.gitignore` | Bench output, editor files. |
| `.gitmodules`, `test/lib/bats-{core,support,assert}` | Pinned test framework. |
| `.shellcheckrc` | `shell=bash`, `external-sources=true`. |
| `.github/workflows/ci.yml` | CI (section 4). |
| `test/helpers/common.bash` | Sandbox, `run_lend`, `assert_class`, `require`. |
| `test/helpers/pty.bash` | `in_pty`: pseudo-terminal via util-linux or BSD `script`. |
| `test/helpers/gpg.bash` | Scratch GnuPG home, key, store, teardown. |
| `test/fixtures/fake-pass` | Mock backend (3.1). |
| `test/fixtures/stub-target` | Records argv0, arguments, `env -0`, `ls -A "$TMPDIR"`, PID, stdin; exits `STUB_EXIT`. |
| `test/fixtures/pinentry-recorder` | Assuan pinentry recording options and PID; answers, cancels or hangs per a mode file. |
| `test/fixtures/profile` | Minimal `~/.profile` adding `~/.local/bin` to PATH, like distribution defaults. |
| `test/fixtures/contract.txt` | Pinned 1.x contract (NFR8). |
| `test/*.bats` | Tests, flat, so `bats test/*.bats` never collects the submodules' own tests. |
| `test/bench/bench.bash` | NFR1, NFR2 timing. |
| `test/lint-repo.bash` | NFR9 plus static NFR3, NFR6, NFR7 checks; skips itself and `test/lib/`. |

Reference documentation is `--help` only, no man page. Shell integration is `lend init` output, no extra files.

## 2. Tooling

| Tool | Pin | Invocation |
|---|---|---|
| bats-core | v1.14.0, commit `eb7f42f` | submodule, `test/lib/bats-core/bin/bats` |
| bats-support | v0.3.0, `24a72e1` | submodule |
| bats-assert | v2.2.4, `f1e9280` | submodule |
| shellcheck | 0.11.0 | `uvx --from shellcheck-py==0.11.0.1 shellcheck` |
| shfmt | 3.14.1 | `uvx --from shfmt-py==4.2.0 shfmt -d` |
| actionlint | 1.7.12 | `uvx --from actionlint-py==1.7.12.25 actionlint` |
| bash 4.4 | `bash:4.4.23-alpine3.22` | `make test-bash44` (Docker) |
| actions/checkout | v7.0.1, `3d3c42e` | full SHA in YAML |
| astral-sh/setup-uv | v10.2.0, `c18668a` | full SHA in YAML |

Submodules pin by commit and need no Node or network in the bash 4.4 container.

Make targets, none needing root:
- `deps`: `git submodule update --init` for the three submodules; `test` depends on `test/lib/bats-core/bin/bats`.
- `lint`: shellcheck and shfmt on `bin/lend`, `test/**/*.bash`, shell fixtures, `test/*.bats`; actionlint; `test/lint-repo.bash`.
- `test`: `bats test/*.bats`. `test-mock`: `bats --filter-tags '!gpg' test/*.bats`.
- `test-net`: the suite under `strace -f -e trace=connect`; fails on any `AF_INET` or `AF_INET6` (NFR6).
- `test-bash44`: `test-mock` in the pinned image as a non-root user.
- `bench`: NFR1, NFR2; nonzero exit on a miss.
- `check`: `lint`, then `test`. The one local command.

## 3. Test strategy

### 3.1 Harness
- Sandbox per test under `BATS_TEST_TMPDIR`: `home/` (HOME), `tmp/` (TMPDIR), `store/` (PASSWORD_STORE_DIR), `log/` (backend and target records), `bin/` (stubs, fake `pass`). `XDG_*`, `LEND_*`, `PASSWORD_STORE_*` (except the dir), `GNUPGHOME` and test key names are unset; `PWD`, `SHLVL` stay set. Sentinels are random, prefixed `lend-sentinel-`.
- `run_lend` runs lend with stdin from `/dev/null` and stderr captured, so calls are non-interactive whatever terminal runs `make`, and asserts every stderr line matches the 5.3 grammar (FR16 across the suite). `assert_class CLASS` checks the line; no test asserts an exit code alone.
- `fake-pass` prints `store/env/KEY.gpg` (plaintext, so `backend_has` works unchanged); logs argv, `env -0` and PID per call to `log/`; writes `[GNUPG:] ERROR` lines to the `--status-fd` in `PASSWORD_STORE_GPG_OPTS`; obeys `store/env/KEY.mode`: `locked` (85), `cancel` (99), `fail` (other code), `hang` (spawns a child, records both PIDs, sleeps), `slow N`. FR4 and FR17 run on it without strace.
- `in_pty` builds the FR12 matrix: stdin, stderr, both, or neither a terminal.
- `gpg.bash`: per file, GNUPGHOME from `mktemp -d /tmp/lend-gpg.XXXXXX`, `gpg-agent.conf` naming the recorder and `allow-loopback-pinentry`, a passphrase-protected ed25519 key whose user ID has no email, `pass init` into `store/`; per test, `gpgconf --reload gpg-agent` for a cold cache; teardown `gpgconf --kill gpg-agent`. It refuses to run when HOME is not the sandbox. `with_gpg2` prepends a `gpg2` symlink (pass's `--batch` branch).
- `require TOOL` skips when TOOL is absent and fails when TOOL is in `TEST_REQUIRE`, set per CI job. Real-GnuPG files carry `# bats file_tags=gpg`.
- FR17 tests `grep -rF` for the sentinel over `home/`, `tmp/`, bats output and backend argv logs; `store/` and target records hold it by design.

### 3.2 Traceability

| Requirement | Test | Stage |
|---|---|---|
| 4.2 grammar, FR11, FR19 (`run`), FR32, 5.1 values | `test/map.bats`, `test/cli.bats` | M2 |
| FR1 to FR3, FR5 to FR10 | `test/run.bats` | M2 |
| FR24 (`run`) | `test/perms.bats` | M2 |
| FR4, FR17, FR18 | `test/secrets.bats`, strace cases | M3, M9 |
| FR12, FR13 | `test/interactivity.bats` | M3 |
| FR14 | `test/timeout.bats` | M3 |
| FR16 | `run_lend`; `test/messages.bats`, every class in both modes | M2 to M8 |
| FR15; FR30 real | `test/gpg.bats` | M4 |
| FR30 | `test/unlock.bats` | M4 |
| FR19 (`sync`), FR22 lock, FR24 (`sync`), FR25, FR26 | `test/sync.bats`, `test/perms.bats` | M5 |
| FR20, FR21, FR22 concurrency, FR23, FR24 (`add`, `rm`) | `test/add-rm.bats` | M6 |
| FR27 to FR29 | `test/check.bats` | M7 |
| FR24 (`init`), FR31, 4.3 | `test/init.bats`, `test/path.bats` | M8 |
| NFR1, NFR2 timing | `make bench` | M9 |
| NFR2 counts, NFR5 | `test/files.bats` | M9 |
| NFR3 | `test/lint-repo.bash`; bash 4.4, Ubuntu, macOS jobs | M1, M9 |
| NFR4 | CI installs only pass, gnupg, zsh, strace; `make lint` | M1 |
| NFR6 | `make test-net`; `test/lint-repo.bash` | M9 |
| NFR7 | `test/lint-repo.bash`: one file in `bin/`; pass and the store only in `backend_has`, `backend_read` | M1, M2 |
| NFR8 | `test/contract.bats` | M2, M9 |
| NFR9 | `test/lint-repo.bash` | M1 |
| §9, AC4 | `test/install.bats`, `test/e2e.bats` | M10 |
| FR33, AC5 | `test/readme.bats` | M10 |
| AC1 to AC3 | CI jobs; `test/lint-repo.bash` ID coverage | M9, M10 |
| AC6 | macOS job; `docs/release.md` | M10 |

## 4. CI

`.github/workflows/ci.yml` runs on push and pull request, `permissions: contents: read`, checkout with `submodules: true`.

- `lint` (ubuntu-24.04): setup-uv; `make lint`.
- `test`, matrix ubuntu-22.04 (GnuPG 2.2) and ubuntu-24.04 (GnuPG 2.4): `sudo apt-get install -y pass zsh strace`; `TEST_REQUIRE="gpg pass zsh strace script python3 systemd-environment-d-generator"`; `make test`; `make test-net`. Covers AC1, AC2, AC4, AC5.
- `bash44` (ubuntu-24.04): `make test-bash44` runs `apk add --no-cache make coreutils util-linux` as root, then `make test-mock` as uid 1001.
- `bench` (ubuntu-24.04), alone: installs pass; `make bench` (AC3).
- `macos` (macos-15, `continue-on-error: true`): `brew install bash`; asserts PATH's `bash` is 4.4 or later; `make test-mock` (AC6).

strace, zsh and GnuPG cases skip in `bash44` and `macos`, whose `TEST_REQUIRE` omits them.

## 5. Stages

### M1 Skeleton, harness, CI (S)
- Files: section 1 minus README body, CHANGELOG, `docs/release.md`, `test/bench/`, and the `bench`, `install`, `uninstall` targets. `bin/lend`: bash version guard, `--version`, placeholder `--help`, `usage` otherwise. `test/harness.bats` self-tests fake-pass, stub-target, `in_pty`, `run_lend`. `ci.yml` has every job but `bench`.
- Covers: NFR3 guard, NFR4, NFR7 file count, NFR9.
- Done: `make check` green; actionlint clean; `make test-bash44` green where Docker exists; CI green on the first push.

### M2 CLI core, map, `run` (L)
- Files: `bin/lend`, `test/{cli,map,run,perms,messages,contract}.bats`, `test/fixtures/contract.txt`.
- Build: `main "$@"; exit $?`; dispatch; full `--help`; 5.1 interactivity with `LEND_PROMPT`, `LEND_TIMEOUT` validation; `fail CLASS TEXT` choosing the interactive or non-interactive FIX; §8 paths; FR24 map checks; map reader in whole-map and per-CMD modes with grammar, deny and guarded lists, ordered dedup; FR5 resolution; `run` over an untimed `backend_has` and `backend_read`; `exec -a`.
- Covers: FR1 to FR3, FR5 to FR11, FR19 (`run`), FR24 (`run`), FR32, NFR7.
- Done: listed files green; FR1 compares `env -0` exactly; FR6 proves status 7 and SIGTERM delivery.

### M3 Backend contract (M)
- Files: `bin/lend`, `test/{secrets,interactivity,timeout,messages}.bats`.
- Build: `--status-fd=9`, plus `--pinentry-mode error` when non-interactive, appended to `PASSWORD_STORE_GPG_OPTS`; classification from the first `ERROR` code's low 16 bits; backend-only `GPG_TTY` (FR13); bounded call (R5); decrypt all, then export (FR4); `set +x +v` first (FR17).
- Covers: FR4, FR12 to FR14, FR16 to FR18 on the mock.
- Done: FR14 ends within `LEND_TIMEOUT` + 1 s and `kill -0` fails for both recorded PIDs; FR12 covers four terminal layouts times `auto`, `never`, `allow`, invalid; FR18 stub receives piped stdin intact.

### M4 Real GnuPG and `unlock` (M)
- Files: `bin/lend`, `test/helpers/gpg.bash`, `test/fixtures/pinentry-recorder`, `test/{gpg,unlock}.bats`.
- Covers: FR15 (a) to (f) with and without `gpg2`, FR30.
- Done: `test/gpg.bats` green on local GnuPG 2.4 with FR15's time bounds asserted; the user's own GnuPG home and store untouched.

### M5 `sync`, shims, lock, permissions (M)
- Files: `bin/lend`, `test/{sync,perms}.bats`.
- Build: FR25 text with the invoked path made absolute, symlinks unresolved, single quotes escaped; marker-only deletion; foreign files give `write`; 0700 shim directory under umask 000 and 022; `mkdir` lock with PID, 10 s retry, stale break.
- Covers: FR19 (`sync`), FR22, FR24 (`sync`), FR25, FR26.
- Done: a second `sync` changes no byte (`cksum`); shims survive a versioned symlink swap; a removed lend gives `lend-missing` from the shim.

### M6 `add` and `rm` (M)
- Files: `bin/lend`, `test/add-rm.bats`.
- Covers: FR20, FR21, FR22 (20 concurrent `add`), FR23, FR24.
- Done: every FR21 error leaves map and shims byte-identical; symlinked map followed; new map 0600 in a 0700 directory.

### M7 `check` (M)
- Files: `bin/lend`, `test/check.bats`.
- Covers: FR27 to FR29: each FR29 detection, plus a healthy setup with no problem.
- Done: zero backend calls across the file; rows match exact expected text; exit 1 only when something shown has a problem.

### M8 `init` and PATH (M)
- Files: `bin/lend`, `test/{init,path}.bats`.
- Build: `init sh|bash|zsh|systemd`; `init` checks the shim directory (FR24) and prints no code when it is unsafe.
- Tests: hook registered once when sourced twice, bash and zsh; `bash -lc` with `test/fixtures/profile`; `zsh -c` via `~/.zshenv` under a parent that prepended another `gh`; `check` reports shadowing after a virtualenv-style prepend; the environment.d generator lists the shim directory first.
- Covers: FR24 (`init`), FR31, 4.3.

### M9 NFR gates (M)
- Files: `test/bench/bench.bash`, `test/{files,contract,secrets}.bats`, `Makefile`, `ci.yml` (`bench` job).
- NFR1: 50-entry map, keys preset, 20 warmups, then 200 interleaved shim and direct runs of a copied `true` timed with `EPOCHREALTIME`; median and p95 of the difference. NFR2: key protected at `s2k-count 8388608`, primed cache, 50 runs of a 3-key `run`, median.
- `files.bats`: backend call counts per verb; filesystem snapshot around every verb; `tmp/` empty after exit and at exec.
- Strace: `strace -f -v -s 4096 -e trace=execve` shows the sentinel only in the target's execve.
- Covers: NFR1, NFR2, NFR5, NFR6, NFR8, strace halves of FR4 and FR17.
- Done: `make bench` passes locally; `make test-net` clean where strace exists.

### M10 Docs, install, release (M)
- Files: `README.md`, `CHANGELOG.md`, `docs/release.md`, `Makefile` (`install`, `uninstall`), `test/{install,e2e,readme}.bats`, `test/lint-repo.bash`.
- README: quick start between `<!-- quickstart -->` markers, at most five commands, run verbatim by `readme.bats` in a fresh HOME seeded with `test/fixtures/profile` and a scratch key (`pass insert` fed on stdin); each FR33 topic under a heading `readme.bats` checks; the "For AI agents" block FR33 specifies.
- `e2e.bats` (AC4): `make install PREFIX="$HOME/.local"`, 4.3 lines, `add gh GH_TOKEN`; stub `gh` gets the key from interactive bash under `in_pty`, `bash -lc`, `zsh -c` behind a prepended `gh`, Python `subprocess` without a shell started from `sh -lc`, and a nested shim with one backend call; the parent lacks `GH_TOKEN`; `make uninstall` leaves only the map.
- `lint-repo.bash` gains the AC1 check: every FR and NFR ID in the PRD names a test or bench case.
- `docs/release.md`: set the version in `bin/lend`; dated CHANGELOG entry; `make check`, `make bench`; every CI job green, one macOS pass included; tick AC1 to AC6; annotated tag `vX.Y.Z`; GitHub release from the CHANGELOG entry. Making the repository public needs the maintainer's approval.
- Covers: FR33, §9, AC4 to AC6.

## 6. End-user install

```sh
git clone https://github.com/v-bonilla/lend.git
cd lend
make install PREFIX="$HOME/.local"
```

- `install` writes one file: a temporary copy inside `$(DESTDIR)$(PREFIX)/bin`, `chmod 0755`, then `mv -f` onto `lend`. `PREFIX` defaults to `$(HOME)/.local`; `DESTDIR` is honored; a relative `PREFIX` is rejected.
- Upgrade: `git pull && make install`. Versioned: install to `PREFIX="$HOME/.local/opt/lend-X.Y.Z"`, `ln -sfn` it to `~/.local/bin/lend`, run `lend sync` once through the symlink.
- Uninstall: remove the 4.3 lines and `~/.config/environment.d/50-lend.conf`, then `make uninstall` with the install's `PREFIX`. It resolves the shim directory as lend does and deletes files whose second line starts with `# lend shim `, a lock whose owner is gone, the directory if empty, and `$(PREFIX)/bin/lend`; never the map, store or rc files.

## 7. Implementation risks and rules

- R1 No `set -e`; failures go through explicit checks and `fail`. `set -u -o pipefail` on; optional variables read as `${VAR-}`. Bash 4.4 accepts empty `"${arr[@]}"` under `set -u`. `IFS=$' \t\n'` and `set -f` first; map fields split with `read -ra`, so no word globs.
- R2 `local x=$(cmd)` masks the status: declare, then assign (SC2155).
- R3 Values live in an associative array: never exported until just before `exec -a`, never in argv, never in here-strings or here-docs (bash before 5.1 backs those with temp files).
- R4 FR1: lend never alters a variable the target inherits; children get shim-free `PATH`, `GPG_TTY`, `PASSWORD_STORE_GPG_OPTS`, `LC_ALL=C` as per-command prefixes. Bash adds `PWD` and `SHLVL=0` only when the caller lacks them (measured); tests keep both set, as shells do. An exported `SHELLOPTS` carries lend's `set` changes to the target, so lend restores the caller's options after the exports, xtrace last, just before `exec`.
- R5 Bounded call without `timeout` or `setsid`: inside the command substitution capturing the value, `set -m` gives the backend its own process group; a watchdog subshell, stdout and stderr on `/dev/null`, sleeps N seconds, marks the timeout, then sends the group TERM and, 1 s later, KILL; the parent waits, then kills the watchdog's group. The substitution's stderr goes to the call's temp file, so job notices never reach lend's stderr. Measured with and without a terminal: instant return on success; a hanging backend and its child are gone after a 1 s timeout.
- R6 Status and backend stderr go to 0600 files in `mktemp -d "${TMPDIR:-/tmp}/lend.XXXXXX"`, removed by an EXIT trap and before exec. Backend stdin is `/dev/null` (FR18).
- R7 Bash reads scripts incrementally: `install` renames instead of rewriting, and the file ends in `main "$@"; exit $?` on one line.
- R8 NFR1 budget: on the preset-keys path, no subshell or external command per PATH entry or map line; canonicalize (`cd -P`, `pwd -P`, bounded `readlink` loop) only candidate hits; one `ls -ldn` covers the map and its directory; `[[ -O ]]` tests ownership.
- R9 Portability: `bin/lend` uses no `stat`, `readlink -f`, `timeout`, `flock`, `setsid`, `sed -i`, `date +%N`, `EPOCHREALTIME`, `SRANDOM` or `/proc`, enforced by command-position greps in `test/lint-repo.bash`. Allowed, as GNU, BSD and busybox share them: `mktemp -d TEMPLATE`, plain `readlink`, `sleep 0.1` for lock retries. Only `in_pty` calls `script`.
- R10 macOS `/bin/bash` 3.2 first on a caller's PATH: the opening lines parse in 3.2, test `BASH_VERSINFO`, and print a `usage` line naming bash 4.4.
- R11 Unix socket paths are length-limited, so test GnuPG homes live under `/tmp`.
- R12 Root bypasses permission checks: the bash 4.4 job tests as non-root; foreign-owner cases use root-owned `/etc` paths and skip as root.
- R13 CI timing noise: paired interleaved runs after warmups, in a job of its own.
- R14 zsh hands `PREFIX=~/.local` to make unexpanded: the Makefile rejects relative `PREFIX`; docs write `"$HOME/.local"`.
