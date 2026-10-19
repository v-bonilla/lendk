# Which bats tests run lendk black-box

This note answers issue #16, a research ticket of wayfinder map #15. It sorts every `@test` in `test/*.bats` by what binds it, counts the classes per file, lists what the black-box tests still need from pass and GnuPG, and names the `test/frozen/` lines that mention pass, GnuPG, gpg or bash. It reads the tree of `dev` at f1c5abb. No test, lendk, pass or gpg ran for it.

## Answer

The suite holds 309 tests in 30 files. 148 run lendk black-box. 85 test something other than lendk: the harness, the repo lint, the Makefile, `install.sh` or a doc. The other 76 depend on lendk's internals.

| Class | Tests | What binds the test |
| --- | ---: | --- |
| black-box | 148 | It drives `lendk` or a shim and checks output, exit status, files and the target's environment. |
| single function | 19 | It calls `lendk-fn`, the sandbox's copy of `bin/lendk` without its last line. |
| bash-bound | 16 | It pins bash behavior, or the shape of the bash implementation. |
| backend-bound | 39 | It pins pass, gpg or gpg-agent behavior. |
| source-bound | 2 | It reads or rewrites `bin/lendk` as text. |
| outside lendk | 85 | Its subject is the harness, the repo lint, the Makefile, `install.sh` or a doc. |
| total | 309 | |

The 148 black-box tests split by what they need:

- 57 need only the sandbox and the stub target. 7 of them also plant the write lock's directory.
- 64 need a pass-side fixture: store entries in pass's layout, the fake pass's call logs or modes, or a gpg stub.
- 26 need the release helpers, which build releases by rewriting `bin/lendk`'s text, and no pass-side fixture.
- 1 needs a test hook that `bin/lendk` reads, and plants the write lock's directory.

## Method

- The source is every `@test` line in `test/*.bats` (`grep -c '^@test'` gives 309), each test's body, and its file's `setup`, `setup_file` and `teardown`.
- Each test gets one primary class: the class of the property its name states. A second tag names the class of another of its assertions.
- Issue #16 names four classes. Two more hold the tests those four do not fit. A source-bound test reads or rewrites `bin/lendk` as a file. An outside-lendk test has a subject other than lendk.
- A bash-bound test pins either bash itself (the opening lines under an old bash, xtrace, `SHELLOPTS`, `BASHOPTS`, `POSIXLY_CORRECT`, `EPOCHREALTIME`, exported functions) or the shape of the bash implementation (its variable and function names, its fork count, its helper lookup, its process tree, and the bash it runs a downloaded lendk with).
- A backend-bound test pins pass, gpg or gpg-agent: the options and status codes of ADR 0004, the watchdog and terminal handoff of a backend job in ADR 0005, the backend's environment, or the GnuPG version check.

The Uses column of the per-file tables names what a test needs beyond the sandbox and the stub target:

- store: store entries written as `$SB/store/env/KEY.gpg`, pass's layout. `backend_has` tests that path (`bin/lendk:455`), and the fake pass prints the file.
- pass log: the fake pass's call logs under `$SB/log/pass.PID/`, or its PID log `$SB/log/pids`, read or counted (`test/fixtures/fake-pass:3-5`).
- pass mode: a `KEY.mode` file that makes the fake pass act as a locked store, a canceled or failed decrypt, a slow or hanging backend, a loopback prompt or a 200 kB value (`test/fixtures/fake-pass:6-17`).
- gpg stub: a `gpg` on PATH that prints a GnuPG version, which `check_gnupg` reads (`bin/lendk:760`).
- real GnuPG: `gpg_setup`, which uses the real pass and gpg with a scratch GnuPG home, a GnuPG key, a store and the recording pinentry (`test/helpers/gpg.bash:15-34`).
- lendk-fn: the single-function runner (`test/helpers/common.bash:24-26`).
- test hook: `LENDK_TEST_PAUSE` or `LENDK_TEST_AT`, which `bin/lendk` reads at lines 689, 1231 and 1849.
- release: the `release` helper (`test/helpers/common.bash:158-166`) or the `candidate` helper (`test/upgrade.bats:143-154`).
- make: `make install` or `make dist`.
- install.sh: the installer.
- write lock layout: the test plants the write lock's directory, `SHIMS.lock/pid` or `SHIMS.lock.break/pid`.
- pty: a pseudo-terminal through `script` (`test/helpers/pty.bash`).
- strace, docker: the tool.

## Counts per file

| File | black-box | single function | bash-bound | backend-bound | source-bound | outside lendk | total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| add-rm.bats | 13 | 0 | 0 | 0 | 0 | 0 | 13 |
| backend-env.bats | 0 | 0 | 0 | 2 | 0 | 0 | 2 |
| check.bats | 17 | 0 | 0 | 1 | 0 | 0 | 18 |
| cli.bats | 3 | 8 | 1 | 0 | 0 | 0 | 12 |
| contract.bats | 2 | 0 | 0 | 0 | 0 | 2 | 4 |
| e2e.bats | 8 | 0 | 0 | 0 | 0 | 0 | 8 |
| files.bats | 5 | 0 | 0 | 0 | 0 | 0 | 5 |
| gpg.bats | 0 | 0 | 0 | 11 | 0 | 0 | 11 |
| guard.bats | 0 | 0 | 3 | 2 | 0 | 1 | 6 |
| harness.bats | 0 | 0 | 0 | 0 | 0 | 12 | 12 |
| init.bats | 9 | 0 | 0 | 0 | 0 | 0 | 9 |
| install.bats | 0 | 0 | 0 | 0 | 0 | 8 | 8 |
| installer.bats | 0 | 0 | 0 | 0 | 0 | 32 | 32 |
| interactivity.bats | 0 | 0 | 0 | 4 | 0 | 0 | 4 |
| lint.bats | 0 | 0 | 0 | 0 | 0 | 16 | 16 |
| lock.bats | 9 | 0 | 0 | 0 | 0 | 0 | 9 |
| map.bats | 4 | 1 | 0 | 0 | 0 | 0 | 5 |
| messages.bats | 0 | 5 | 0 | 0 | 0 | 0 | 5 |
| net.bats | 2 | 0 | 0 | 1 | 1 | 0 | 4 |
| path.bats | 2 | 0 | 0 | 0 | 0 | 0 | 2 |
| perms.bats | 4 | 0 | 0 | 0 | 0 | 0 | 4 |
| readme.bats | 0 | 0 | 0 | 0 | 0 | 9 | 9 |
| run.bats | 12 | 4 | 7 | 0 | 0 | 0 | 23 |
| secrets.bats | 9 | 1 | 1 | 2 | 0 | 0 | 13 |
| signals.bats | 0 | 0 | 0 | 13 | 0 | 0 | 13 |
| skill.bats | 0 | 0 | 0 | 0 | 0 | 5 | 5 |
| sync.bats | 15 | 0 | 0 | 0 | 0 | 0 | 15 |
| timeout.bats | 0 | 0 | 1 | 2 | 0 | 0 | 3 |
| unlock.bats | 5 | 0 | 0 | 1 | 0 | 0 | 6 |
| upgrade.bats | 29 | 0 | 3 | 0 | 1 | 0 | 33 |
| total | 148 | 19 | 16 | 39 | 2 | 85 | 309 |

35 tests carry a second tag:

- 11 black-box tests: 6 source-bound, 3 bash-bound, 2 backend-bound.
- 2 single-function tests: 1 black-box, 1 bash-bound.
- 6 bash-bound tests: 3 black-box, 2 source-bound, 1 backend-bound.
- 5 backend-bound tests: 4 black-box, 1 bash-bound.
- 11 outside-lendk tests: 6 source-bound, 4 black-box, 1 backend-bound.

## The tests that are not black-box

### Single function (19)

Each calls one of lendk's functions through `lendk-fn`:

- `load_env`, through the `settings` helper (`test/cli.bats:10-13`): `cli.bats` 66, 77, 93, 102, 112, 122 and 132.
- `declare -F` after the file is sourced, which runs the opening lines: `cli.bats` 58.
- `fail` and the `classes` table, through `fail_line` (`test/messages.bats:11-19`): all 5 tests of `messages.bats`.
- `main run` with `backend_has` and `read_values` replaced, through `run_fake` (`test/run.bats:21-24`): `run.bats` 45, 75, 154 and 177.
- `expand_keys`, after a black-box call: `map.bats` 75.
- `read_values` on a 200 kB store entry: `secrets.bats` 159.

### Bash-bound (16)

- The opening lines under bash 3.2 and 4.3 in containers, and under the current bash: `guard.bats` 18, 26 and 36.
- Caller shell state that bash reads: exported functions named like commands and builtins (`cli.bats` 44) or like lendk's own functions (`run.bats` 256), `SHELLOPTS` (`run.bats` 67), `BASHOPTS` (`run.bats` 306), `POSIXLY_CORRECT` (`run.bats` 269), variables named like lendk's internals (`run.bats` 278), `bash -x` and `SHELLOPTS=xtrace` (`secrets.bats` 170), and `EPOCHREALTIME` under bash 4.4 (`timeout.bats` 52).
- The shape of the bash implementation: its fork count on the run path under strace (`run.bats` 205), its helper utilities found through `command -p` (`run.bats` 313), and the watchdog found as a subshell under lendk (`upgrade.bats` 798, lines 811-814).
- `upgrade` running the downloaded lendk with the bash that runs the upgrade, under a TEXT that names bash (`upgrade.bats` 357 and 366; `bin/lendk:1809-1810`).

### Backend-bound (39)

- Options and status codes, ADR 0004 (11): `interactivity.bats` 25 and 54, `unlock.bats` 56, `secrets.bats` 58, and `gpg.bats` 43, 58, 72, 85, 99, 173 and 192.
- The watchdog and terminal handoff of a backend job, ADR 0005 (19): all 13 tests of `signals.bats`, `timeout.bats` 26 and 41, and `gpg.bats` 112, 128, 151 and 161.
- The backend's environment (5): `backend-env.bats` 49 and 58, `interactivity.bats` 80 and 95, and `secrets.bats` 73.
- The GnuPG version check (3): `check.bats` 197, and `guard.bats` 55 and 81.
- No network from real GnuPG (1): `net.bats` 71.

12 of them use real pass, gpg and gpg-agent: the 11 tests of `gpg.bats` and `net.bats` 71. The other 27 use the fake pass, or in `secrets.bats` 58 a stand-in that prints gpg's error lines.

### Source-bound (2)

- `net.bats` 83 greps `bin/lendk` for its network region.
- `upgrade.bats` 531 rewrites the `LENDK_VERSION=` line of the installed copy.

14 more tests carry source-bound as a second tag. `upgrade.bats` 176, 338, 357, 366, 378, 477, 516 and 640 read or rewrite the second line or the `LENDK_VERSION=` line. `installer.bats` 336 compares the installer's markers with `bin/lendk`'s second line. `lint.bats` 100, 106, 117, 136 and 145 plant lines in `bin/lendk` for the rules of `test/lint-repo.bash:38-70`.

### Outside lendk (85)

- The harness (14): all 12 tests of `harness.bats`, `guard.bats` 107 (the guard of `gpg.bash`) and `contract.bats` 43 (the frozen comparison).
- The repo lint (16): `lint.bats`.
- The Makefile (8): `install.bats`.
- The installer (32): `installer.bats`. Its setup stubs `gpg` and `pass` for every test (`test/installer.bats:41-42`). Tests 76, 113, 144, 160, 174, 192, 202, 218, 261, 300, 424 and 434 name bash, pass or GnuPG in what they assert.
- The docs (15): all 9 tests of `readme.bats`, all 5 of `skill.bats` and `contract.bats` 59.

4 of them compare a doc or the frozen lists with `lendk --help`: `contract.bats` 43 and 59, `readme.bats` 153 and `skill.bats` 25. `readme.bats` 202 runs the README's quick start with real pass and gpg.

## What the black-box tests still need from pass and GnuPG

Every test runs in the sandbox, which links the fake pass as `pass` first on PATH and sets `PASSWORD_STORE_DIR` to `$SB/store` (`test/helpers/common.bash:15` and `:22`). A black-box test that never reaches the backend still runs with them in place.

| Fixture | Black-box tests | Other tests |
| --- | ---: | ---: |
| store layout | 62 | 30 |
| fake pass call logs | 31 | 17 |
| fake pass modes | 1 | 18 |
| gpg stub | 41 | 3 |
| real GnuPG: `gpg_setup` and the recording pinentry | 0 | 13 |

- The store layout (62): all 13 tests of `add-rm.bats`; `check.bats` 55, 64, 75, 98, 109, 118, 129, 146, 157, 169, 179, 186, 205, 219 and 242; all 8 of `e2e.bats`; all 5 of `files.bats`; `net.bats` 30 and 53; both of `path.bats`; `secrets.bats` 39, 50, 91, 107, 124, 137, 145, 194 and 205; `unlock.bats` 24, 32, 40, 74 and 86; `upgrade.bats` 176, 290 and 688.
- The fake pass's call logs (31) serve four purposes:
  - to show that no backend read happened: the `check.bats` teardown, for its 16 black-box tests other than 205 (`test/check.bats:17-20` and `:53`), `secrets.bats` 39 and 50, `unlock.bats` 40 and 86, and `upgrade.bats` 176 and 290;
  - to count backend reads: `add-rm.bats` 47, `files.bats` 38, 54 and 96, and `e2e.bats` 106;
  - to read which store entries unlock read, in order, from pass's argv: `unlock.bats` 24 and 32;
  - to read the modes of the backend's stderr file and the backend's stdin: `secrets.bats` 107 and 194.
- The fake pass's modes (1): `files.bats` 65 uses mode `locked` to reach class `locked`.
- The gpg stub (41): the setups of `add-rm.bats`, `check.bats`, `e2e.bats` and `path.bats`, and `upgrade.bats` 688.
- Real GnuPG, `gpg_setup` and the recording pinentry serve no black-box test. They serve the 11 tests of `gpg.bats`, `net.bats` 71 and `readme.bats` 202.
- `family` and `none_within` (`test/helpers/common.bash:96-125`) find a call's processes by the inherited `LENDK_TEST_FAMILY` and by the fake pass's PID log. The black-box upgrade tests that use them make no fake pass call, so they rely on `LENDK_TEST_FAMILY` alone.

## What the black-box tests need from the bash implementation

- `LENDK` is `$ROOT/bin/lendk`, set once (`test/helpers/common.bash:4`). `upgrade.bats`, the `release` helper and `installer.bats` also read `$ROOT/bin/lendk` or `../bin` directly (`test/upgrade.bats:9`, `:11`, `:21`, `:26`, `:34`, `:149`, `:243`, `:461`, `:489`, `:524`, `:536`, `:551`, `:590`, `:706`, `:709` and `:720`; `test/helpers/common.bash:161`; `test/installer.bats:9` and `:21`).
- 31 black-box tests use releases built from `bin/lendk`'s text: `release` rewrites the `LENDK_VERSION=` line, and `candidate` writes a bash script that starts with lendk's second line. These are `net.bats` 30 and 53 and all 29 black-box tests of `upgrade.bats`. `upgrade` itself checks the second line of the installed file and of the downloaded one, and runs the downloaded one with `$BASH` (`bin/lendk:1807-1810` and `:1872-1875`; ADR 0014).
- 4 black-box tests set a test hook that `bin/lendk` reads: `lock.bats` 72, `secrets.bats` 205, and `upgrade.bats` 668 and 749. `signals.bats` 129 and `upgrade.bats` 798 set one too.
- 9 black-box tests install through `make install` or `make dist`, which copy `bin/lendk` and read its `LENDK_VERSION=` line (`Makefile:45-48` and `:70-76`): all 8 of `e2e.bats` and `upgrade.bats` 688.
- 9 black-box tests plant the write lock's directory: `lock.bats` 28, 38, 45, 59, 72, 94, 104 and 116, and `add-rm.bats` 175. The layout is lendk's own on-disk format, written by `take_lock` and `break_lock` (`bin/lendk:1183` and `:1213`), not bash's.

## `test/frozen/` lines that mention pass, GnuPG, gpg or bash

| Line | Text | Where `bin/lendk` holds it |
| --- | --- | --- |
| `verbs:7` | `lendk init sh\|bash\|zsh\|systemd` | `bin/lendk:960`, bash as the login shell `init` writes for |
| `lists:1` | `reserved commands: lendk bash pass gpg gpg2 gpg-agent gpgconf` | `bin/lendk:139` |
| `lists:2` | `denied key prefixes: BASH LENDK_ PASSWORD_STORE_ GNUPG GPG_ LD_ DYLD_ LC_ XDG_` | `bin/lendk:141` |
| `fixes:3` | `Put a newer bash first on PATH.` | class `unsupported`, `bin/lendk:174` |
| `fixes:4` | `Upgrade GnuPG.` | class `unsupported`, `bin/lendk:175` |
| `fixes:10` | `Add it: pass insert env/KEY` | class `missing-key`, `bin/lendk:182` |
| `fixes:11` | `Set it: pass edit env/KEY` | class `missing-key`, `bin/lendk:185` |
| `fixes:13` | `Add a mapped key with pass insert, then retry.` | class `missing-key`, `bin/lendk:184` |
| `fixes:14` | `See gpg's error: lendk unlock KEY` | class `decrypt`, `bin/lendk:186` |
| `variables:1` | `GPG_TTY` | `bin/lendk:977` |
| `variables:9` | `PASSWORD_STORE_DIR` | `bin/lendk:974` |

Other frozen lines carry bash or GnuPG without those words:

- `lists:3`, the denied key names, holds `PINENTRY_USER_DATA`, a GnuPG variable, and shell variables that bash rejects or keeps for itself, such as `SHELLOPTS`, `RANDOM`, `SECONDS`, `EPOCHREALTIME` and `PIPESTATUS` (ADR 0009).
- In `classes`, `locked`, `canceled` and `decrypt` come from gpg's status codes (ADR 0004), and `unsupported` covers both a bash below 4.4 and a GnuPG below 2.4.
- `shim` names none of them: the shim runs under `/bin/sh` and execs `lendk run --`.

## Per-file lists

Each table lists a file's tests by class, then by line.

### add-rm.bats

13 tests: 13 black-box.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 47 | add creates an entry, syncs and prints its row in check format | black-box |  | store, pass log, gpg stub |
| 60 | add appends only absent words, in order, before a trailing comment | black-box |  | store, gpg stub |
| 77 | rm removes words, the entry when none remain, and the shim with it | black-box |  | store, gpg stub |
| 96 | a guarded command needs --force, and --force gives a notice naming the risk | black-box |  | store, gpg stub |
| 116 | every add and rm error leaves the map and shims byte-identical | black-box |  | store, gpg stub |
| 148 | removing an absent name or word exits 0 with a notice | black-box |  | store, gpg stub |
| 163 | add and rm need the whole map valid | black-box |  | store, gpg stub |
| 175 | twenty concurrent adds started with a dead owner's lock leave twenty entries | black-box |  | store, gpg stub, write lock layout |
| 195 | the map is 0600 in a 0700 directory under umask 000, and only the edited line changes | black-box |  | store, gpg stub |
| 210 | a symlinked map is followed, and the link stays | black-box |  | store, gpg stub |
| 226 | add and rm give unsafe for an open map, map directory or shim directory | black-box |  | store, gpg stub |
| 248 | rows for non-interactive callers say ask the user, never add or rm | black-box |  | store, gpg stub |
| 257 | an unknown group creates nothing, and its FIX says to define the group | black-box |  | store, gpg stub |

### backend-env.bats

2 tests: 2 backend-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 49 | a direct call's backend gets only the allowlisted environment | backend-bound | bash-bound | store, pass log |
| 58 | under a nested shim, the inner backend sees neither the outer key nor the caller's | backend-bound | black-box | store, pass log |

### check.bats

18 tests: 17 black-box, 1 backend-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 55 | check calls no backend read, and an empty value shows as ok | black-box |  | store, pass log, gpg stub |
| 64 | a healthy setup gives headers and ok rows, groups first, sorted, exit 0 | black-box |  | store, pass log, gpg stub |
| 75 | check NAME keeps rows named NAME, holding key NAME, or using group NAME | black-box |  | store, pass log, gpg stub |
| 89 | interactive calls get the full FIX; lendk sync and lendk run -- CMD stay non-interactive | black-box |  | pass log, gpg stub |
| 98 | check reports a map violation on its row, or as a problem line when no row holds it | black-box |  | store, pass log, gpg stub |
| 109 | check reports a key missing from the store on each row that uses it | black-box |  | store, pass log, gpg stub |
| 118 | check reports a mapped command not on PATH outside the shim directory | black-box |  | store, pass log, gpg stub |
| 129 | check reports a missing, a stale and a stray shim, each with lendk sync as the fix | black-box |  | store, pass log, gpg stub |
| 146 | check reports a foreign file in the shim directory, named like a mapped command or not | black-box |  | store, pass log, gpg stub |
| 157 | check reports a shim whose lendk path is not executable | black-box |  | store, pass log, gpg stub |
| 169 | check reports a map and a shim directory writable by others, without reading the store | black-box |  | store, pass log, gpg stub |
| 179 | check reports a shim directory not on PATH | black-box |  | store, pass log, gpg stub |
| 186 | check reports a shadowed shim, naming the earlier path | black-box |  | store, pass log, gpg stub |
| 205 | check reports a mapped key set in the environment, unless lendk injected it | black-box |  | store, gpg stub |
| 219 | exit 1 only when a shown item has a problem | black-box |  | store, pass log, gpg stub |
| 228 | a fresh install with no map, or an empty one, is no problem: exit 0 and a notice | black-box |  | pass log, gpg stub |
| 242 | a shim that lost its mode 0755 is stale | black-box |  | store, pass log, gpg stub |
| 197 | check reports a GnuPG below 2.4 | backend-bound |  | store, pass log, gpg stub |

### cli.bats

12 tests: 3 black-box, 8 single function, 1 bash-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 15 | --help prints the reference to stdout and exits 0 | black-box |  |  |
| 23 | --version prints lendk X.Y.Z | black-box |  |  |
| 30 | no arguments, an unknown verb, or extra words after --help or --version are usage | black-box |  |  |
| 58 | inherited functions are gone before any command runs | single function | bash-bound | lendk-fn |
| 66 | default paths follow HOME | single function |  | lendk-fn |
| 77 | absolute XDG values move the defaults and relative ones are ignored | single function |  | lendk-fn |
| 93 | LENDK_MAP, LENDK_SHIMS, PASSWORD_STORE_DIR and LENDK_PREFIX override the defaults | single function |  | lendk-fn |
| 102 | LENDK_PROMPT accepts auto, never and allow; allow makes the default timeout 60 s | single function |  | lendk-fn |
| 112 | any other LENDK_PROMPT is usage | single function |  | lendk-fn |
| 122 | LENDK_TIMEOUT accepts 1 to 3600 and applies to both modes | single function |  | lendk-fn |
| 132 | any other LENDK_TIMEOUT is usage | single function |  | lendk-fn |
| 44 | exported functions named like commands and builtins leave --help and --version byte-identical | bash-bound | black-box |  |

### contract.bats

4 tests: 2 black-box, 2 outside lendk.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 39 | --help carries every frozen verb, list word, class, FIX and variable | black-box |  |  |
| 68 | sync writes the frozen shim text | black-box |  |  |
| 43 | a renamed or removed entry fails the comparison while an added one or a changed verb description passes | outside lendk | black-box |  |
| 59 | the README's name lists and classes are the lines --help prints | outside lendk | black-box |  |

### e2e.bats

8 tests: 8 black-box.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 75 | the from-source setup installs lendk, writes the map and the shim, and the parent lacks GH_TOKEN | black-box |  | store, gpg stub, make |
| 82 | interactive bash in a terminal gets the key | black-box |  | store, gpg stub, make, pty |
| 89 | bash -lc gets the key | black-box |  | store, gpg stub, make |
| 94 | zsh -c under a parent that prepended another gh gets the key | black-box |  | store, gpg stub, make |
| 100 | Python subprocess without a shell, started from sh -lc like a desktop session, gets the key | black-box |  | store, gpg stub, make |
| 106 | a nested shim reuses the key with one decrypt | black-box |  | store, pass log, gpg stub, make |
| 112 | after the from-source setup, systemd's environment.d generator puts the shim directory first | black-box |  | store, gpg stub, make |
| 118 | removing the blocks and make uninstall leave only the map | black-box |  | store, gpg stub, make |

### files.bats

5 tests: 5 black-box.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 38 | run reads each key the caller did not set, once, and unlock each key it names | black-box |  | store, pass log |
| 54 | check, sync, add, rm, init, --help and --version make no backend read | black-box |  | store, pass log |
| 65 | run, unlock, check, init, --help and --version leave the filesystem unchanged | black-box |  | store, pass mode |
| 83 | sync, add and rm write only the map, its directory and the shim directory | black-box |  | store |
| 96 | TMPDIR is empty when the target starts | black-box |  | store, pass log |

### gpg.bats

11 tests: 11 backend-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 43 | a cold non-interactive call gives locked within 2 s and never launches pinentry | backend-bound |  | real GnuPG |
| 58 | after priming through loopback a non-interactive call succeeds | backend-bound |  | real GnuPG |
| 72 | LENDK_PROMPT=allow launches pinentry | backend-bound |  | real GnuPG |
| 85 | with stdin piped and stderr a terminal, pinentry gets that terminal as ttyname | backend-bound |  | real GnuPG, pty |
| 99 | Cancel in pinentry gives canceled | backend-bound |  | real GnuPG |
| 112 | a pinentry that never answers gives timeout within 4 s and is gone afterwards | backend-bound |  | real GnuPG |
| 128 | KILL to lendk's process group while pinentry waits leaves no pinentry within 2 s | backend-bound |  | real GnuPG |
| 151 | with loopback in gpg.conf the passphrase typed into the terminal reaches gpg, and the target gets the value | backend-bound |  | real GnuPG, pty |
| 161 | with loopback in gpg.conf, a call in a command substitution gives locked and shows no prompt | backend-bound |  | real GnuPG, pty |
| 173 | unlock with a pinentry primes the cache for non-interactive calls | backend-bound |  | real GnuPG |
| 192 | unlock without a terminal is a probe that gives locked on a cold cache | backend-bound |  | real GnuPG |

### guard.bats

6 tests: 3 bash-bound, 2 backend-bound, 1 outside lendk.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 18 | bash 3.2 gives unsupported with exit 125 | bash-bound |  | docker |
| 26 | bash 4.3 gives unsupported with exit 125, and the interactive FIX when prompting is allowed | bash-bound |  | docker |
| 36 | the current bash passes the guard | bash-bound | black-box |  |
| 55 | run and unlock give unsupported for a gpg below 2.4, before any decrypt | backend-bound |  | store, pass log, gpg stub |
| 81 | the GnuPG version parses strictly, and gpg --version runs under the allowlisted environment | backend-bound |  | store, gpg stub |
| 107 | gpg.bash aborts when HOME or GNUPGHOME lies outside the sandbox | outside lendk |  |  |

### harness.bats

12 tests: 12 outside lendk.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 9 | sandbox: HOME, TMPDIR and the store are private, and no key or lendk variable leaks in | outside lendk |  |  |
| 19 | fake-pass: prints the entry and logs argv, environment and PID | outside lendk |  |  |
| 31 | fake-pass: a missing entry fails like pass | outside lendk |  |  |
| 37 | stub-target: logs argv0, arguments and environment, and exits STUB_EXIT | outside lendk |  |  |
| 45 | run_lendk: rejects a stderr line outside the contract | outside lendk |  |  |
| 55 | run_lendk: rejects a non-interactive forbidden suggestion | outside lendk |  |  |
| 66 | run_lendk: refuses upgrade on the working tree's lendk, and the sandbox's download tools fail | outside lendk |  |  |
| 84 | run_lendk: rejects a call that started one of the sandbox's download tools | outside lendk |  |  |
| 94 | run_lendk: captures stdout, stderr and status with stdin at /dev/null | outside lendk |  |  |
| 104 | gone: a live process is not gone, a zombie and a reaped one are | outside lendk |  |  |
| 133 | require: skips an absent tool and fails one TEST_REQUIRE lists | outside lendk |  |  |
| 140 | require: every tool TEST_REQUIRE lists is present | outside lendk |  |  |

### init.bats

9 tests: 9 black-box.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 20 | init sh moves the shim directory to the front of PATH once, keeping every other entry | black-box |  |  |
| 31 | init reads no map and holds the absolute shim directory, quotes escaped | black-box |  |  |
| 43 | the bash hook registers once when its block runs twice, and repeats the move with hash -r | black-box |  |  |
| 56 | the zsh hook registers once when its block runs twice, and repeats the move with rehash | black-box |  |  |
| 69 | init systemd prints PATH with the shim directory, then ${PATH} | black-box |  |  |
| 74 | systemd's environment.d generator puts the shim directory first | black-box |  |  |
| 83 | init gives unsafe and prints no code for a shim directory open to others | black-box |  |  |
| 93 | init without one of sh, bash, zsh or systemd is usage | black-box |  |  |
| 103 | the zsh block runs under nounset, and init rejects a relative LENDK_SHIMS | black-box |  |  |

### install.bats

8 tests: 8 outside lendk.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 17 | install: copies bin/lendk to PREFIX/bin with mode 0755 and nothing else | outside lendk |  | make |
| 25 | install: a second install gives the file a new inode, and an open copy keeps its old file | outside lendk |  | make |
| 38 | install: DESTDIR prefixes the target | outside lendk |  | make |
| 44 | install: a relative PREFIX is rejected before anything is written | outside lendk |  | make |
| 51 | uninstall: removes marker-bearing shims, the empty shim directory and lendk, never the map | outside lendk |  | make |
| 62 | uninstall: keeps a foreign file and the shim directory holding it | outside lendk |  | make |
| 70 | uninstall: leaves a foreign lendk in PREFIX/bin and says so | outside lendk |  | make |
| 79 | uninstall: removes the default data directory only when empty | outside lendk |  | make |

### installer.bats

32 tests: 32 outside lendk.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 76 | installer: a fresh install puts lendk in ~/.local/bin and the shims first on the login PATH | outside lendk |  | install.sh |
| 92 | installer: a rerun changes nothing, and earlier content of the login file stays | outside lendk |  | install.sh |
| 104 | installer: zsh users also get ~/.zshenv, and ~/.bash_profile wins over ~/.profile | outside lendk |  | install.sh |
| 113 | installer: a first bash older than 4.4 gets a newer one put first in the block | outside lendk |  | install.sh |
| 127 | installer: --version picks the release by tag, and a missing release is a download failure | outside lendk |  | install.sh |
| 135 | installer: a checksum mismatch installs nothing | outside lendk |  | install.sh |
| 144 | installer: missing deps print the package manager command and stop; --install-deps runs it | outside lendk |  | install.sh |
| 160 | a failed package manager run prints the command to run by hand, and sudo -v when sudo is in it | outside lendk |  | install.sh |
| 174 | the package command refreshes the index and skips recommended packages for each manager | outside lendk |  | install.sh |
| 192 | pacman never runs a partial upgrade; on failure the line says to run pacman -Syu first | outside lendk |  | install.sh |
| 202 | installer: piped into bash -s and sh -s, as curl \| bash runs it, with a package manager that reads stdin | outside lendk |  | install.sh |
| 218 | installer: without bash 4.4 it names bash as a missing dependency | outside lendk |  | install.sh |
| 226 | installer: without curl or wget, or without tar, it names the missing tool | outside lendk |  | install.sh |
| 240 | installer: zsh users on macOS also get the block in ~/.zprofile | outside lendk |  | install.sh |
| 248 | installer: a rerun with another --prefix replaces the login block | outside lendk |  | install.sh |
| 261 | installer: on macOS without Homebrew it points to brew.sh and installs nothing | outside lendk |  | install.sh |
| 271 | installer: --no-modify-path and --prefix leave every login file alone | outside lendk |  | install.sh |
| 279 | installer: --skill-dir copies the agent skill, and --uninstall with it removes the copy | outside lendk |  | install.sh |
| 290 | installer: with a systemd user session it writes the environment.d file | outside lendk |  | install.sh |
| 300 | installer: --uninstall removes the blocks, shims and lendk, never the map or the store | outside lendk |  | install.sh |
| 315 | installer: --uninstall keeps a lendk it did not write | outside lendk |  | install.sh |
| 323 | installer: bad options are usage errors | outside lendk |  | install.sh |
| 336 | installer: its markers match the ones bin/lendk and the Makefile use | outside lendk | source-bound | install.sh |
| 344 | installer: runs to the end under dash, busybox sh and the system bash | outside lendk |  | install.sh |
| 357 | installer: a truncated download installs nothing, since main runs on the last line | outside lendk |  | install.sh |
| 367 | installer: a login file without a final newline keeps its last line, across a rerun and an uninstall | outside lendk |  | install.sh |
| 381 | installer: a quote in the prefix stays quoted in the login block | outside lendk |  | install.sh |
| 391 | installer: the final line comes on a bad HOME and on a signal; the temporary directory goes | outside lendk |  | install.sh |
| 415 | installer: a base URL other than https:// or file:/// is refused | outside lendk |  | install.sh |
| 424 | installer: an uninitialized store gets steps a human runs in their own terminal | outside lendk |  | install.sh |
| 434 | installer: runs under bash 3.2 and stops on missing deps | outside lendk |  | install.sh, docker |
| 444 | installer: installs end to end under dash on Ubuntu and busybox sh on Alpine | outside lendk |  | install.sh, docker |

### interactivity.bats

4 tests: 4 backend-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 25 | the matrix of terminal stdin and stderr and LENDK_PROMPT sets the backend options | backend-bound |  | store, pass log, pty |
| 54 | gpg's status code, not its text, classifies failures, per interactivity | backend-bound |  | store, pass mode |
| 80 | an interactive backend gets stdin's terminal as GPG_TTY, else stderr's; the target never does | backend-bound | black-box | store, pass log, pty |
| 95 | a caller GPG_TTY naming a character device stays, any other is replaced, and non-interactive calls add none | backend-bound |  | store, pass log, pty |

### lint.bats

16 tests: 16 outside lendk.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 28 | the repository passes lint-repo.bash | outside lendk |  |  |
| 34 | the unchanged scratch copy passes lint-repo.bash | outside lendk |  |  |
| 41 | lint-repo.bash skips gitignored build output such as dist/ | outside lendk |  |  |
| 50 | lint-repo.bash flags a planted em-dash | outside lendk |  |  |
| 56 | lint-repo.bash flags a planted reference to the retired spec | outside lendk |  |  |
| 63 | lint-repo.bash flags planted FR, NFR and AC IDs and accepts H, A and G IDs | outside lendk |  |  |
| 77 | lint-repo.bash flags a planted email address | outside lendk |  |  |
| 84 | lint-repo.bash flags a home path other than /home/alice and accepts /home/alice | outside lendk |  |  |
| 94 | lint-repo.bash flags a license held by someone else | outside lendk |  |  |
| 100 | lint-repo.bash flags a second file in bin/ | outside lendk | source-bound |  |
| 106 | lint-repo.bash flags pass or the store named outside the two backend functions | outside lendk | source-bound |  |
| 117 | lint-repo.bash flags non-portable commands in bin/lendk, except in the name-list tables | outside lendk | source-bound |  |
| 136 | lint-repo.bash allows /proc and ps only in the terminal-owner test | outside lendk | source-bound |  |
| 145 | lint-repo.bash allows curl and wget only in the network region | outside lendk | source-bound |  |
| 174 | lint-repo.bash flags script outside the test helpers | outside lendk |  |  |
| 180 | bats-core is the pinned submodule and shellcheck is pinned through uvx | outside lendk |  |  |

### lock.bats

9 tests: 9 black-box.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 28 | sync breaks a dead owner's lock and leaves no lock behind | black-box |  | write lock layout |
| 38 | sync breaks a lock that never got an owner after 1 s | black-box |  | write lock layout |
| 45 | a live owner's lock gives write naming the lock after 10 s | black-box |  | write lock layout |
| 59 | concurrent syncs started with a dead owner's lock all finish, one at a time | black-box |  | write lock layout |
| 72 | a waiter killed while holding the break marker leaves a lock the next sync breaks | black-box |  | write lock layout, test hook |
| 94 | a break marker that never got a PID is taken over after 1 s | black-box |  | write lock layout |
| 104 | a live waiter's break marker is left alone, so the lock stays until it is done | black-box |  | write lock layout |
| 116 | runtime calls never lock | black-box |  | write lock layout |
| 125 | a trailing slash on LENDK_SHIMS keeps the lock beside the shim directory | black-box |  |  |

### map.bats

5 tests: 4 black-box, 1 single function.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 25 | run reads only its own line and groups; bad lines elsewhere leave it working | black-box |  |  |
| 32 | a violation in run's own line or groups is map, with its line | black-box |  |  |
| 57 | lendk's own runtime cannot be mapped | black-box | bash-bound |  |
| 64 | a named group must be defined; named keys need no map | black-box |  |  |
| 75 | groups expand in word order and duplicates drop, keeping the first | single function | black-box | lendk-fn |

### messages.bats

5 tests: 5 single function.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 21 | every class gives one contract line and its exit hint, in both modes | single function |  | lendk-fn |
| 35 | non-interactive FIXes hand the step to the user, or point to lendk --help | single function |  | lendk-fn |
| 46 | interactive FIXes name the command, key, path and entry prefix | single function |  | lendk-fn |
| 58 | without LENDK_PROMPT, a call with no terminal gets the non-interactive FIX | single function |  | lendk-fn |
| 64 | a substituted value is never rewritten again, by the prefix or by another token | single function |  | lendk-fn |

### net.bats

4 tests: 2 black-box, 1 backend-bound, 1 source-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 30 | no verb connects to an internet address | black-box |  | store, release, strace |
| 53 | no verb starts a download tool, upgrade from a file:// base included | black-box |  | store, release |
| 71 | run and unlock with real GnuPG connect to no internet address | backend-bound |  | real GnuPG, strace |
| 83 | the source names curl and wget only in the network region, and no nc or /dev/tcp | source-bound |  |  |

### path.bats

2 tests: 2 black-box.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 37 | bash -lc with the skel profile reaches the shim once init sh is appended | black-box |  | store, gpg stub |
| 46 | zsh -c behind a prepended gh reaches the shim through ~/.zshenv | black-box |  | store, gpg stub |

### perms.bats

4 tests: 4 black-box.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 19 | a private map in a private directory passes, also under umask 000 | black-box |  |  |
| 26 | a map or directory writable by group or others is unsafe | black-box |  |  |
| 44 | a symlinked map is judged by its target and the target's directory | black-box |  |  |
| 56 | a map owned by another user is unsafe | black-box |  |  |

### readme.bats

9 tests: 9 outside lendk.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 37 | the README covers every topic | outside lendk |  |  |
| 78 | the install command for humans is the quick start's first command | outside lendk |  |  |
| 84 | the Contents list links every section, and every in-page link names a heading | outside lendk |  |  |
| 97 | uninstall has a section of its own, and elsewhere only the option list and links name it | outside lendk |  | install.sh |
| 115 | the Upgrade section sits between Installation and Uninstall and covers the verb, its trust and the installer's part | outside lendk |  |  |
| 138 | the README's statements about network use name lendk upgrade alone | outside lendk |  |  |
| 153 | the agent prompt covers every step, with only real installer options, classes and lendk verbs | outside lendk | black-box | install.sh |
| 182 | the credential helper snippet leaves only lendk's helper after none, or after gh's two | outside lendk |  |  |
| 202 | the README's quick start runs as written and gh then receives GH_TOKEN | outside lendk | backend-bound | real GnuPG, make, install.sh |

### run.bats

23 tests: 12 black-box, 4 single function, 7 bash-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 55 | with every key preset, only LENDK_INJECTED is added; exported functions and variables named like lendk's own stay | black-box | bash-bound |  |
| 84 | the first executable regular file on PATH runs, skipping the shim directory however it is reached | black-box |  |  |
| 99 | a CMD holding / is used as given, and a CMD found nowhere else is not-found | black-box |  |  |
| 111 | the target gets argv0 as given, its arguments unchanged, and its status passes through | black-box |  |  |
| 124 | lendk becomes the target, so SIGTERM reaches it | black-box |  |  |
| 139 | a target exec cannot run gives exec, never bash's own message | black-box |  |  |
| 166 | a CMD without an entry and without named keys is unmapped | black-box |  |  |
| 184 | run without -- is usage, naming a word that is a command | black-box |  |  |
| 196 | named words must be valid, allowed keys or groups | black-box |  |  |
| 234 | when the kernel refuses the file, lendk's exec line ends stderr, also under a caller BASHOPTS without execfail | black-box | bash-bound |  |
| 287 | keys named lendk_ in any case are denied | black-box |  |  |
| 296 | a CMD whose basename breaks the CMD grammar is usage | black-box |  |  |
| 45 | the target's environment is the caller's plus the injected keys and LENDK_INJECTED | single function |  | lendk-fn |
| 75 | a key set non-empty by the caller is not read and keeps its value; an empty one is read | single function |  | lendk-fn |
| 154 | named keys replace the map entry, and without them the entry for CMD's basename applies | single function |  | lendk-fn |
| 177 | LENDK_INJECTED holds the caller's names, then the names this call exported, once each | single function |  | lendk-fn |
| 67 | an exported SHELLOPTS reaches the target with the caller's options | bash-bound |  |  |
| 205 | the preset path forks as often for a 50-line map and a long PATH as for one line and a short PATH | bash-bound |  | strace |
| 256 | caller functions named like lendk's own leave the exec error path intact | bash-bound |  |  |
| 269 | an exported POSIXLY_CORRECT reaches the target unchanged, and lendk runs | bash-bound |  |  |
| 278 | caller variables named like lendk's internals change nothing | bash-bound |  |  |
| 306 | a caller BASHOPTS with nocasematch does not make STUB match stub | bash-bound |  |  |
| 313 | lendk's own helpers come from the system path, never from PATH or the shims | bash-bound |  |  |

### secrets.bats

13 tests: 9 black-box, 1 single function, 1 bash-bound, 2 backend-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 39 | every missing key is listed before any decrypt, and the command does not run | black-box |  | store, pass log |
| 50 | the command resolves before anything is decrypted | black-box |  | store, pass log |
| 91 | under strace the sentinel appears only in the target's execve, and there only in its environment | black-box |  | store, strace |
| 107 | the target gets the caller's umask and descriptors, and lendk's files are private, under umask 000 and 022 | black-box | backend-bound | store, pass log |
| 124 | the target's open descriptors are exactly those of a direct call | black-box |  | store |
| 137 | the value is the first line without its newline, spaces and glob characters kept | black-box |  | store |
| 145 | an empty first line or an empty entry is missing-key | black-box |  | store |
| 194 | lendk leaves stdin to the target, and the backend's stdin is /dev/null | black-box | backend-bound | store, pass log |
| 205 | LENDK_TEST_PAUSE never changes a decrypt's output or class, and no value reaches stderr | black-box |  | store, test hook |
| 159 | a 200 kB first line reads in under 1 s | single function |  | lendk-fn, store, pass mode |
| 170 | the sentinel reaches no output, file or helper, also under bash -x and an exported SHELLOPTS=xtrace | bash-bound | black-box | store, pass log |
| 58 | a failed decrypt stops the call with gpg's last line, and the command does not run | backend-bound |  | store |
| 73 | a later backend call sees no key read earlier; all keys reach the target | backend-bound | black-box | store, pass log |

### signals.bats

13 tests: 13 backend-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 45 | TERM, INT or HUP to lendk leaves no backend, child or watchdog behind | backend-bound |  | store, pass log, pass mode |
| 56 | TERM or KILL to lendk's process group leaves no backend, child or watchdog behind | backend-bound |  | store, pass log, pass mode |
| 69 | after expiry and after exec, nothing of the call is left | backend-bound |  | store, pass log, pass mode |
| 84 | a loopback prompt gets the terminal once and its typed line; the target gets the line | backend-bound |  | store, pass log, pass mode, pty |
| 95 | Ctrl-C at a loopback prompt gives canceled | backend-bound |  | store, pass mode, pty |
| 103 | a pipeline neighbor using the terminal runs while the backend works | backend-bound |  | store, pass mode, pty |
| 110 | lendk in a background job gives timeout and leaves the shell's terminal alone | backend-bound |  | store, pass mode, pty |
| 119 | with stderr redirected to a file, a loopback prompt still gets the terminal | backend-bound |  | store, pass mode, pty |
| 129 | a signal before lendk records the job's PID leaves nothing behind | backend-bound |  | store, pass log, pass mode, test hook |
| 140 | in a command substitution, which cannot take the terminal, a configured loopback prompt gives locked without prompting | backend-bound |  | store, pass log, pass mode, pty |
| 148 | in a command substitution without loopback configured, the backend may still prompt through pinentry | backend-bound |  | store, pass log, pty |
| 154 | a pipeline neighbor that reads the terminal during a loopback prompt resumes afterwards | backend-bound |  | store, pass mode, pty |
| 164 | under umask 000, lendk's files for the backend phase are private | backend-bound |  | store, pass log, pass mode, pty |

### skill.bats

5 tests: 5 outside lendk.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 16 | SKILL.md has Agent Skills frontmatter naming lendk, and stays concise | outside lendk |  |  |
| 25 | the skill's verbs and classes are the ones lendk --help prints | outside lendk | black-box |  |
| 41 | the skill's installer classes and options are the ones install.sh uses | outside lendk |  | install.sh |
| 48 | the skill exempts exactly the README's approved installation test, and sync is safe | outside lendk |  |  |
| 59 | the skill says upgrade leaves its copy as it is, names --skill-dir to refresh it, and carries the agent rule | outside lendk |  |  |

### sync.bats

15 tests: 15 black-box.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 31 | sync writes one shim per mapped command, mode 0755, naming lendk by its invoked path | black-box |  |  |
| 49 | a lendk path holding a single quote is escaped, and the shim runs | black-box |  |  |
| 60 | shims survive a versioned upgrade behind a stable symlink | black-box |  |  |
| 77 | a shim whose lendk is gone gives lendk-missing, exit 127 | black-box |  |  |
| 90 | a second sync changes no byte | black-box |  |  |
| 105 | sync rewrites a stale shim and deletes only marker-bearing shims of unmapped commands | black-box |  |  |
| 120 | a foreign file named like a mapped command stays and gives write after the other shims | black-box |  |  |
| 133 | sync writes shims for every valid command line, then reports each violation | black-box |  |  |
| 149 | several violations on one line are reported in word order | black-box |  |  |
| 157 | sync without a map writes no shim and removes the old ones | black-box |  |  |
| 166 | sync creates the shim directory 0700 under any umask | black-box |  |  |
| 177 | sync gives unsafe for a shim directory open to others or a map open to others | black-box |  |  |
| 193 | sync gives unsafe for a shim directory owned by another user | black-box |  |  |
| 201 | sync restores a shim's mode 0755, and removes a killed sync's temporary file | black-box |  |  |
| 213 | a shim directory other than this call's is skipped, so a shim never runs itself | black-box |  |  |

### timeout.bats

3 tests: 1 bash-bound, 2 backend-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 52 | a caller's EPOCHREALTIME, garbage or frozen, cannot stretch the bound under bash 4.4 | bash-bound | backend-bound | store, pass mode |
| 26 | a hanging backend gives timeout after LENDK_TIMEOUT and before LENDK_TIMEOUT + 2 s | backend-bound |  | store, pass mode |
| 41 | the bound covers every key of the call, not each key | backend-bound |  | store, pass mode |

### unlock.bats

6 tests: 5 black-box, 1 backend-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 24 | unlock decrypts each named key, groups inlined, prints unlocked and no value | black-box |  | store, pass log |
| 32 | without names, unlock decrypts the first mapped key present in the store | black-box |  | store, pass log |
| 40 | no mapped key present gives missing-key, and a missing named key too | black-box |  | store, pass log |
| 74 | unlock reads only the lines its groups need | black-box |  | store |
| 86 | unlock gives unsafe for a group-writable map or map directory | black-box |  | store, pass log |
| 56 | unlock follows run's classes: locked, canceled, timeout, usage | backend-bound | black-box | store, pass mode |

### upgrade.bats

33 tests: 29 black-box, 3 bash-bound, 1 source-bound.

| Line | Test | Class | Second tag | Uses |
| ---: | --- | --- | --- | --- |
| 176 | upgrade replaces lendk with the latest release and touches nothing else | black-box | source-bound | release, store, pass log |
| 203 | an argument is usage, stdin is never read, and a terminal changes only the FIX | black-box |  | release |
| 223 | an https base goes through curl with https-only options | black-box |  | release |
| 237 | without curl, wget downloads, with --https-only where it has it | black-box |  | release |
| 258 | a base that is not https:// or file:///, or holds a blank, is usage, and a set base is named in a notice | black-box |  | release |
| 275 | a missing tool is upgrade before anything is fetched, and a file base needs no curl or wget | black-box |  | release |
| 290 | a mapped curl runs without its shim and gets no key, and the tools' output stays out | black-box |  | release, store, pass log |
| 311 | a failed download and one cut short change nothing | black-box |  | release |
| 325 | another checksum, or SHA256SUMS without the asset, changes nothing | black-box |  | release |
| 338 | an archive without lendk, or holding a file that is not lendk, changes nothing | black-box | source-bound | release |
| 378 | the member's directory and --version name one version, written without leading zeros or overflow | black-box | source-bound | release |
| 390 | an archive that does not unpack, or a fetch that ends without a result, is a local failure | black-box |  | release |
| 413 | no other verb reads LENDK_INSTALL_BASE_URL | black-box |  | release |
| 427 | with shasum and no sha256sum the upgrade succeeds | black-box |  | release |
| 442 | the tools get /dev/null as stdin | black-box |  | release |
| 457 | an unset or empty LENDK_INSTALL_BASE_URL is the project's releases, with no notice | black-box |  | release |
| 477 | a release that is not newer is up to date, also for an install ahead of it, compared number by number | black-box | source-bound | release |
| 502 | a symlinked lendk is refused before any fetch | black-box |  | release |
| 516 | a file that is not lendk's, or a directory the user cannot write, is refused before any fetch | black-box | source-bound | release |
| 544 | the upgrade is a rename: a new inode, and an open descriptor keeps the old bytes | black-box |  | release |
| 557 | two upgrades at once, and add calls alongside, all succeed and leave one whole file | black-box |  | release |
| 583 | sync runs through the new file, and with an invalid map line the upgrade stands | black-box |  | release |
| 627 | a download that never returns gives upgrade after LENDK_TIMEOUT and before LENDK_TIMEOUT + 2 s | black-box |  | release |
| 640 | a candidate whose --version never returns gives upgrade within LENDK_TIMEOUT + 2 s and leaves nothing | black-box | source-bound | release |
| 652 | TERM, INT, HUP or KILL during the fetch leaves no tool, watchdog, temporary directory or staged file | black-box |  | release |
| 668 | KILL between staging and the rename removes the staged file and keeps lendk | black-box |  | release, test hook |
| 688 | install.sh, then upgrade, against make dist releases | black-box |  | release, store, gpg stub, make, install.sh |
| 749 | TERM, INT or HUP before the watchdog starts removes both files and is re-raised | black-box |  | release, test hook |
| 773 | TERM, INT, HUP or KILL after an expiry, while the watchdog stops a tool that ignores TERM, leaves nothing | black-box |  | release |
| 357 | a lendk that does not run under this bash changes nothing | bash-bound | source-bound | release |
| 366 | a candidate that exits non-zero, or prints anything but lendk X.Y.Z, changes nothing | bash-bound | source-bound | release |
| 798 | when the watchdog dies, its rescue removes the staged file of a killed lendk | bash-bound |  | release, test hook |
| 531 | an install whose version is not X.Y.Z is refused before any fetch | source-bound |  | release |
