# lend implementation plan

This plan takes lend from an empty repository to v1.0.0 as `docs/prd.md` specifies; the PRD wins any conflict. Stages M1 to M13 run in order, and each depends only on earlier ones. M13 deletes this file.

A stage is done when its Done line holds, all tests so far pass, `make check` and `make check-docker` exit 0, and the ID lint passes: each FR and NFR ID of the PRD sits in a test name (`@test "FRn: ..."`) or in `test/pending-ids`, never both, and the stage has moved its own IDs out. No Done line depends on remote CI.

## 1. Layout

| Path | Purpose |
|---|---|
| `bin/lend` | The tool: one bash file (NFR7) holding every verb, the `init` code, and the tables `--help` prints (NFR8). |
| `Makefile` | `deps lint test check check-docker bench install uninstall`. |
| `README.md`, `CHANGELOG.md`, `LICENSE` | FR37; Keep a Changelog 1.1.0 with SemVer; MIT, `v-bonilla`. |
| `docs/prd.md`, `docs/plan.md`, `docs/release.md` | Requirements; this plan, deleted in M13; release steps. |
| `.editorconfig`, `.gitignore`, `.shellcheckrc` | LF and tabs for shell; bench output; `shell=bash`. |
| `.gitmodules`, `test/lib/bats-core` | The one submodule. |
| `.github/workflows/ci.yml`, `.github/dependabot.yml` | CI (2.3); weekly `github-actions` pin updates. |
| `test/docker/ubuntu.Dockerfile`, `test/docker/bash44.Dockerfile` | `make check-docker` images (2.2). |
| `test/helpers/common.bash` | Sandbox, `run_lend`, `assert_class`, `assert_eq`, `assert_line`, `refute_contains`, `require`, `gone`. |
| `test/helpers/pty.bash`, `test/helpers/gpg.bash` | `in_pty`, `in_shell`; scratch GnuPG home, key and store. |
| `test/fixtures/` | `fake-pass`, `stub-target`, `pinentry-recorder`, `profile` and `bashrc` mirroring Debian's `/etc/skel`. |
| `test/pending-ids` | FR and NFR IDs without a test yet; M13 deletes it. |
| `test/*.bats`, `test/bench/bench.bash`, `test/lint-repo.bash` | Tests, flat so `bats test/*.bats` skips the submodule's own; NFR1 and NFR2 timing; repo lint. |

## 2. Tooling and gates

### 2.1 Pins

| Tool | Pin | Use |
|---|---|---|
| bats-core | v1.14.0, `eb7f42f` | submodule, `test/lib/bats-core/bin/bats` |
| shellcheck | 0.11.0 | `uvx --from shellcheck-py==0.11.0.1 shellcheck` |
| images | `ubuntu:24.04`, `bash:4.4.23-alpine3.22`, `bash:4.3.48`, `bash:3.2.57` | `make check-docker` |
| actions/checkout | v7.0.1, `3d3c42e` | full SHA in YAML |
| astral-sh/setup-uv | v10.2.0, `c18668a` | full SHA in YAML |

There is no formatter, workflow linter or assertion library; the helpers in `common.bash` stay under 60 lines.

### 2.2 Make targets

- `deps`: `git submodule update --init`.
- `lint`: shellcheck on `bin/lend`, `test/**/*.bash`, shell fixtures and `test/*.bats`; then `test/lint-repo.bash`.
- `test`: `bats --filter-tags '!docker' test/*.bats` on the host. `check`: `lint`, then `test`.
- `check-docker`: builds both images (cached); runs the `docker`-tagged files on the host, which start `bash:3.2.57` and `bash:4.3.48` for FR22; then, with the worktree mounted read-only and uid 1000, runs the suite in the Ubuntu image (`pass gnupg zsh strace python3 git make systemd`, `--cap-add SYS_PTRACE`, `TEST_REQUIRE="gpg pass zsh strace script python3 git environment-d"`) and the mock suite in the bash 4.4 image (busybox userland without GNU coreutils; `util-linux-misc` adds `script`; `TEST_REQUIRE=script`).
- `bench`: NFR1 and NFR2; nonzero exit on a miss.
- `install`, `uninstall`: PRD section 9.

### 2.3 CI

`ci.yml` runs on push and pull request with `permissions: contents: read`, checkout with submodules, runners `ubuntu-latest`: `check` (setup-uv, `make check`), `docker` (`make check-docker`), `bench` (`make bench`, `continue-on-error: true`), `macos` (`macos-latest`, `brew install bash gnupg pass`, `make test`, `continue-on-error: true`). Its first run is the release push to the private repository (AC6).

## 3. Test strategy

### 3.1 Harness

- Each test gets a sandbox under `BATS_TEST_TMPDIR`: `home/` (HOME), `tmp/` (TMPDIR), `store/`, `log/`, `bin/`. `XDG_*`, `LEND_*`, `PASSWORD_STORE_*` except the directory, `GNUPGHOME` and key names are unset; `PWD` and `SHLVL` stay. Sentinels are random, prefixed `lend-sentinel-`.
- `run_lend` runs lend with stdin `/dev/null`, captures stderr and asserts every line matches PRD 5.3 (FR19 across the suite). No test asserts an exit code alone.
- `gone PID` holds when `/proc/PID/stat` is absent or shows state `Z`: gpg-agent leaves an interrupted pinentry as a zombie, so `kill -0` misleads.
- `fake-pass` prints `store/env/KEY.gpg` (plaintext); logs argv, `env -0` and PID per call; writes `[GNUPG:] ERROR` lines to the `--status-fd` descriptor; obeys `store/env/KEY.mode`: `locked` (85), `cancel` (99), `fail`, `hang` (records its PID and a child's, sleeps interruptibly), `stubborn` (a child ignoring TERM), `slow N`, `big` (a 200 kB first line), `tty` (loopback stand-in: `stty -echo`, then a line from `/dev/tty`).
- `pinentry-recorder` speaks Assuan, records options and PID, and answers, cancels or hangs per a mode file; it hangs with `sleep & wait` and exits on INT, TERM or HUP, as real pinentries do.
- `in_pty CMD` runs CMD under `script`, typing input on a schedule; `in_shell` types into `bash --norc -i` in a pty, for pipelines and background jobs.
- `gpg.bash`: GNUPGHOME from `mktemp -d /tmp/lend-gpg.XXXXXX` (R11); `gpg-agent.conf` naming the recorder, with `allow-loopback-pinentry`; a passphrase-protected ed25519 key whose user ID has no email; `pass init` into `store/`. `gpgconf --kill gpg-agent` runs between tests, since an interrupted pinentry's zombie blocks the next prompt. It aborts unless HOME and GNUPGHOME are sandbox paths. `with_gpg2` prepends a `gpg2` symlink.
- `require TOOL` skips when TOOL is absent and fails when TOOL is in `TEST_REQUIRE`. Tags: `gpg` for real GnuPG, `docker` for files that start containers.
- strace runs as `strace -f --seccomp-bpf`, so FR16 and FR18 time bounds hold under it.

### 3.2 Traceability

| Requirement | Test | Stage |
|---|---|---|
| FR22 (bash), NFR3 (static), NFR4, NFR7 (one file), NFR9 | `guard.bats`, `lint.bats` | M1 |
| FR9, FR36, NFR8 (lists, classes), 5.1 values | `cli.bats`, `contract.bats` | M2 |
| FR19 | `run_lend`; `messages.bats`, which each later stage extends with its classes | M2 |
| FR1, FR2, FR5, FR6, FR11 to FR13, FR23 (`run`), FR28 (`run`), NFR1 | `map.bats`, `run.bats`, `perms.bats`, `make bench` | M3 |
| FR3, FR4, FR7, FR8, FR10, FR20, FR21, NFR7 (backend functions) | `secrets.bats`, `backend-env.bats` | M4 |
| FR14 to FR17 | `interactivity.bats`, `timeout.bats`, `signals.bats` | M5 |
| FR18, FR22 (GnuPG), FR23 (`unlock`), FR28 (`unlock`), FR34 | `gpg.bats`, `unlock.bats`, `guard.bats` | M6 |
| FR23 (`sync`), FR26 (lock), FR28 (`sync`), FR29, FR30, NFR8 (shim) | `sync.bats`, `lock.bats`, `contract.bats` | M7 |
| FR31 to FR33 | `check.bats` | M8 |
| FR23 (`add`, `rm`), FR24, FR25, FR26 (twenty `add`), FR27, FR28 (`add`, `rm`) | `add-rm.bats` | M9 |
| FR28 (`init`), FR35, 4.3 | `init.bats`, `path.bats` | M10 |
| Section 9, AC4 | `install.bats`, `e2e.bats` | M11 |
| NFR2, NFR5, NFR6 | `files.bats`, `net.bats`, `make bench` | M12 |
| FR37, NFR8 (README), 4.4, AC5 | `readme.bats`, `contract.bats` | M13 |
| AC1, AC2, AC3 | `make check`, `make check-docker`, `make bench`, ID lint | M13 |
| AC6 | `docs/release.md` | release |

## 4. Stages

Sizes: S fits a short pass, M a full one; no stage is larger.

### M1 Skeleton and gates (M)
- Files: the section 1 skeleton without README, CHANGELOG, `docs/release.md`, bench and install targets; `bin/lend` with the bash guard, `--version` and `usage`; `common.bash`; `fake-pass` (plain and logging) and `stub-target`; `test/lint-repo.bash`; `test/pending-ids`; `test/{harness,guard,lint}.bats`.
- `lint-repo.bash`: NFR9; the R9 greps; one file in `bin/`; the ID lint.
- Done: `guard.bats` gives `unsupported` with exit 125 under `bash:3.2.57` and `bash:4.3.48`; `lint.bats` shows `lint-repo.bash` failing on a scratch copy with a planted em-dash, email address, home path other than `/home/alice`, or PRD ID found neither in a test nor in `pending-ids`; the planted strings are assembled at run time, so the repository never holds them.

### M2 CLI surface (S)
- `main "$@"; exit $?`; inherited functions removed first (FR9); dispatch; the tables (verbs, classes with hints and both FIXes, name lists, variables) and `--help` printed from them; `fail CLASS TEXT` choosing the FIX by 5.1; `LEND_PROMPT` and `LEND_TIMEOUT` validation; section 8 paths.
- Done: `contract.bats` extracts every list and class from the PRD and finds each in `--help`; exported functions `printf`, `env` and `mktemp` leave `--help` output byte-identical.

### M3 Map reader and `run` with preset keys (M)
- Per-command map reader: grammar, deny, reserved and guarded lists, group expansion with ordered dedup; FR28 map checks; FR5 resolution; `run` with every key preset; export; `LEND_INJECTED`; `exec -a` under `shopt -s execfail`.
- Done: the FR1 `env -0` diff holds exactly the keys, `LEND_INJECTED`, `_`, `PWD` and `SHLVL`; status 7 and SIGTERM reach the target; a failed exec gives `lend: exec:`; the NFR1 part of `make bench` exits 0 on the host.

### M4 Decrypt path (M)
- `backend_has`, and `backend_read` without a bound: `exec env -i ALLOWLIST pass show` with stdin `/dev/null`; first line per R3; FR3 order; export after all decrypts; `set +x +v`; temporary directory per R6; `fake-pass` mode `big`; the NFR7 lint that only the two backend functions name pass or the store.
- Done: the sentinel appears nowhere FR20 forbids, also under `bash -x` and `SHELLOPTS=xtrace`; the fake pass records exactly FR8's environment, directly and under a nested shim; the target sees the caller's umask and descriptors under umask 000; the strace halves of FR4 and FR20 pass in check-docker; `big` reads in under 1 s on bash 4.4.

### M5 Bounded backend (M)
- R5 in full: status fd, `--pinentry-mode error` when non-interactive, classification, backend-only `GPG_TTY`, watchdog, `coproc` job, traps, terminal handoff; `fake-pass` modes `locked`, `cancel`, `fail`, `slow`, `hang`, `stubborn`, `tty`; `in_pty`, `in_shell`.
- Done, on the host and in the bash 4.4 image:
  - The FR14 matrix covers stdin, stderr, both or neither a terminal, times `auto`, `never`, `allow` and an invalid value.
  - `hang` and `stubborn` with `LEND_TIMEOUT=2` give `timeout` after 2.0 s and before 4.0 s.
  - After TERM, INT or HUP to lend, TERM or KILL to its group, and expiry, every recorded PID is gone within 2 s.
  - Under `in_shell`: `tty` mode reads its typed line with one handoff, and Ctrl-C gives `canceled`.
  - A pipeline neighbor running `stty` finishes with no `Stopped` line.
  - `lend run ... &` gives `timeout` and leaves the shell's terminal alone.

### M6 Real GnuPG and `unlock` (M)
- `gpg.bash`, `pinentry-recorder`, the GnuPG version check, `unlock`.
- Done: FR18 (a) to (h) pass in the Ubuntu image with and without `gpg2`; a stub gpg reporting 2.2.27 gives `unsupported`; `gpg.bash` aborts when HOME or GNUPGHOME lies outside the sandbox.

### M7 `sync`, shims, lock (M)
- Whole-map reader; FR29 text with the invoked path made absolute, symlinks unresolved, single quotes escaped; marker-only deletion; foreign files give `write`; 0700 shim directory; the lock per R15.
- Done: a second `sync` leaves every shim's `cksum` unchanged; shims survive a versioned symlink swap; a removed lend gives `lend-missing` from the shim; `sync` breaks a dead owner's lock and gives `write` naming a live owner's lock after 10 s.

### M8 `check` (M)
- FR31 to FR33, with a row formatter that M9 reuses.
- Done: zero backend calls across the file; each FR33 detection has a test with its exact row or line; exit 1 only when a shown item has a problem, 0 for a healthy setup.

### M9 `add` and `rm` (M)
- FR24, FR25, FR27, the guarded list with `--force` and its notice, sync after each edit, rows in `check` format.
- Done: every FR25 error leaves map and shims byte-identical; twenty concurrent `add` calls started with a dead owner's lock leave twenty entries; the map is 0600 after writes under umask 000; a symlinked map is followed.

### M10 `init` and PATH (S)
- FR35 blocks between markers; FR28 for `init`.
- Done: the hook registers once when its block runs twice, in bash and zsh; `bash -lc` with the skel fixtures and `zsh -c` behind a prepended `gh` both reach the shim; `init` prints no code and gives `unsafe` for a group-writable shim directory.

### M11 Install and end-to-end (M)
- `install` (temporary file in `$(DESTDIR)$(PREFIX)/bin`, mode 0755, rename; relative `PREFIX` rejected) and `uninstall`.
- Done: `e2e.bats` passes AC4 in the Ubuntu image; `make install` over an existing lend gives the file a new inode; `make uninstall` leaves only the map.

### M12 NFR gates (S)
- `files.bats`: backend call counts per verb, a filesystem snapshot around every verb, TMPDIR empty after exit and at exec. `net.bats`: every verb under `strace -f --seccomp-bpf -e trace=connect`. Bench NFR2: key at `s2k-count 8388608`, warm cache, 50 runs of a 3-key `run`.
- Done: `net.bats` sees no AF_INET or AF_INET6 connect in the Ubuntu image; `make bench` exits 0 on the host.

### M13 README and release (M)
- README per FR37, quick start between `<!-- quickstart -->` markers, lists and classes as `--help` prints them. CHANGELOG 1.0.0; `docs/release.md`; version 1.0.0. `readme.bats` (AC5) builds its clone source as a scratch repository from the working tree, so it runs from any checkout.
- Done: `readme.bats` passes in the Ubuntu image; `contract.bats` matches the README's lists to `--help`; `lend --version` prints `lend 1.0.0`; `test/pending-ids` and `docs/plan.md` are deleted and no file names them; the PRD mentions no stage.

`docs/release.md`: dated CHANGELOG entry; the three make gates; create the GitHub repository private, push, wait for green CI (AC6); annotated tag `v1.0.0`; GitHub release from the CHANGELOG entry. Making the repository public needs the maintainer's approval.

## 5. Implementation rules

- R1 No `set -e`; failures go through explicit checks and `fail`. `set -u -o pipefail`; optional variables read as `${VAR-}`; empty `"${arr[@]}"` is safe under `set -u` from bash 4.4. `IFS=$' \t\n'` and `set -f` first; map fields split with `read -ra`.
- R2 `local x=$(cmd)` masks the status: declare, then assign (SC2155).
- R3 Values live in an associative array in the main shell. They are never exported before exec, never in argv, never in here-strings or here-docs, which bash before 5.1 backs with temp files. The first line comes from `IFS=$'\n'` splitting under `set -f`, after an empty-first-line test, never `${v%%$'\n'*}`. That pattern is quadratic: a 200 kB value took 10.8 s on bash 4.4 and 0.97 s on 5.2, against 0.01 s for splitting (measured).
- R4 lend changes nothing the target inherits. At startup lend records `SHELLOPTS` and `BASHOPTS`, leaves POSIX mode (an exported `POSIXLY_CORRECT` keeps its value), and turns off every option outside bash's defaults; before exec it restores them and keeps `execfail`. Exported functions are re-defined and re-exported just before exec; after that point lend uses only positional parameters and builtins, and the `exec` line for a failed exec is prepared before it. The umask changes only in subshells or in verbs that never exec; descriptors opened for the backend close before exec; bash adds `PWD` and `SHLVL` only when missing. An exported `SHELLOPTS` carries lend's `set` changes, so lend restores the caller's options just before exec, xtrace last. Before exec it resets every trap it set, so the target gets default dispositions.
- R5 Bounded backend (FR16, FR17), measured with mock backends on bash 4.4.23 (busybox) and 5.2, and with pass 1.7.4 and GnuPG 2.4.4 on bash 5.2. The main shell L runs the phase with two helper jobs:
  - L saves stderr (`exec {err}>&2`) and, when stdin is a terminal, points fd 2 at it (`2<&0`): bash finds and hands over the terminal through fd 2, reading it when job control starts. Then `set -m`. While job control is on, L runs builtins only, since a foreground external command would become a job and take the terminal. Afterwards: `set +m`, fd 2 restored.
  - W, the watchdog, starts as `( ... ) </dev/null >/dev/null 2>&1 &`: a background job in its own process group, which signals aimed at lend's group miss. After each `sleep 0.1` it sends L `USR1` (interactive calls only), then checks. L gone (`kill -0`) means abandon. `SECONDS` ≥ N + 1 or 10·N ticks means timeout, never early and at most 1 s late. To act, W ignores TERM, writes a `timeout` mark (timeout) or deletes the temp directory (abandon), sends TERM and CONT to J's group, waits up to 0.5 s, then sends KILL.
  - J, the backend job, starts as a `coproc`: a background job in its own group whose stdout is a pipe. L dups the read end at once, because bash closes coproc descriptors when it reaps the job. J records its PID for W and L, traps TERM, INT and HUP to exit 143, 130 and 129 (so bash never reports a killed job), ignores TSTP, sets umask 077, and sends its own stderr to the temp directory. It reads each key with `v=$(exec env -i ALLOWLIST pass show PREFIX/KEY 9>STATUS 2>ERR </dev/null)` and keeps the values in memory. It then prints them and a status line through one forked writer (`{ printf ...; } &`) and exits, so J never waits for L, whatever the sizes.
  - L waits with `wait "$jpid"`, which returns when J exits and whenever a trapped signal arrives. Its TERM, INT and HUP traps kill J's and W's groups, delete the temp directory and re-raise the signal. Its USR1 trap does nothing.
  - When `wait` returns with J alive, L reads `jobs -sp`. The handoff needs two facts. First, J has stopped on the terminal: a loopback prompt calls tcsetattr from a background group and gets SIGTTOU. Second, lend's group owns the terminal: field 8 of `/proc/$$/stat` equals field 5, or, where `/proc` is absent, `ps -o tpgid= -o pgid=` read through a process substitution, which job control leaves in lend's group. Then L runs `fg`: bash gives J the terminal, continues it, and takes the terminal back when J exits.
  - Once J is gone, L ignores USR1, kills an idle W with KILL and waits for it (a W that is acting finishes first), drains the pipe with blocking reads, and resets USR1 before exec. Values exist only in that pipe and in shell memory.
  - Why this shape, measured: bash runs a trap only after a command substitution returns (a TERM trap ran at 4 s under `v=$(sleep 4)`, at 1 s under `read`). A job-control shell inside a command substitution never sees its job stop (`jobs -sp` stayed empty with the job in state T), and `wait` never returns on a stop. A backend holding the terminal from the start stops pipeline neighbors (`lend ... | less` showed `Stopped`). `fg` from a background job steals the terminal, then stops lend.
  - Results: N = 2 timed out at 2.14 to 2.16 s (2.6 s with a TERM-ignoring child); every kill case left no backend, W or real pinentry after 1 s; a real loopback prompt took one handoff; M5's other Done cases held.
- R6 The temporary directory comes from `mktemp -d "${TMPDIR:-/tmp}/lend.XXXXXX"` and holds per-key status and stderr files and J's PID. The status descriptor exists only inside J's read (`9>FILE`), so neither L nor the target ever holds it. L removes the directory before exit or exec; W removes it when L dies.
- R7 Bash reads scripts incrementally: `install` renames instead of rewriting, and the file ends in `main "$@"; exit $?` on one line.
- R8 NFR1 budget: on the preset-keys path, no subshell or external command per PATH entry or map line; `-ef` compares candidate hits with the shim directory, and a bounded `readlink` loop runs only for symlinked hits; one `ls -ldn` covers the map and its directory, started as a process substitution before bash parses the rest of the file; `[[ -O ]]` tests ownership; the environment snapshot uses `${!X*}` expansions, and the function purge forks for `declare -F` only when functions exist. `run` dispatches before the other verbs' code, which bash then never parses. lend's `ls` and `readlink` run through `command -p`, never from PATH or the shims.
- R9 Portability greps in `lint-repo.bash` flag `stat`, `readlink -f`, `timeout`, `flock`, `setsid`, `sed -i`, `date +%N`, `EPOCHREALTIME` and `SRANDOM` only in command position (`(^|[;&|(]|\$\()[[:space:]]*WORD\b`) and outside the name-list tables, which hold several of these words as data. `/proc` and `ps` may appear only in the foreground test of R5. Only test helpers call `script`.
- R10 The opening lines of `bin/lend` parse in bash 3.2, test `BASH_VERSINFO`, and give `unsupported` with exit 125.
- R11 Unix socket paths are length-limited, so test GnuPG homes live under `/tmp`.
- R12 Root bypasses permission checks: `check-docker` runs as uid 1000; foreign-owner cases use root-owned paths and skip as root.
- R13 Bench timing uses paired, interleaved runs after warmups; CI only reports it.
- R14 zsh hands `PREFIX=~/.local` to make unexpanded: the Makefile rejects a relative `PREFIX`; docs write `"$HOME/.local"`.
- R15 Lock: `mkdir SHIMS.lock`, then write the PID inside; a lock without a PID file counts as live for 1 s. A waiter that finds the owner dead takes `mkdir SHIMS.lock.break` and writes its PID inside, rereads the owner and, if it is still the same dead PID, removes the lock, then renames `SHIMS.lock.break` away, removes it and retries. A break marker whose PID is dead, or that has no PID after 1 s, is taken over by `mkdir MARKER/break` in the same way, after rereading the dead PID, so a waiter killed while breaking never blocks the next one. Owners remove only their own lock.
