# lendk 1.1.0 implementation plan: `lendk upgrade`

This plan takes lendk from 1.0.0 to 1.1.0 by adding the verb `lendk upgrade` as `docs/prd.md` specifies it (FR45 to FR50, NFR3 to NFR6, NFR8, AC7); the PRD wins any conflict. Stages S1 to S4 run in order. The release commit deletes this file.

## 1. Scope

In scope: `upgrade` in `bin/lendk`, its tests, the lint region for the download tools, the README, skill and CHANGELOG text, and the release preparation.

Non-goals: choosing a release, downgrade, rollback, signature checks; refreshing PATH setup, the environment.d file or a skill copy; any change to `install.sh`, the `Makefile`, the Docker images or the CI workflow; any refactor of `read_values`, `backend_read` or `allow_env`; tagging, pushing and publishing, which stay with the maintainer.

Before S1: the branch is rebased onto `dev`. FR37 conflicts on that rebase, since both branches edit its one line: take `dev`'s sentence and append this branch's two closing sentences, from "It has a section on upgrading" to the end. README sections below carry the names of `dev`'s outline.

## 2. Gates

- One file: `test/lib/bats-core/bin/bats test/NAME.bats`. Repo lint: `bash test/lint-repo.bash`. Host: `make check`. Containers: `make check-docker`. Timing: `make bench`.
- With the PRD ahead of the code, `make check` fails until S2 ends: `contract.bats` counts entries the code lacks, and the ID lint reports FR45 to FR50. Each stage's Done line names the failures it still expects. No stage weakens or deletes a test to get green.
- A stage is done when its Done line holds and every test file it did not expect to fail passes.

## 3. Files

| File | S1 | S2 | S3 | S4 |
|---|---|---|---|---|
| `bin/lendk` | tables, `upgrade_verb`, network region | job, watchdog line | | `LENDK_VERSION` |
| `test/upgrade.bats` (new) | T1 to T17 | T18 to T21 | | |
| `test/helpers/common.bash` | `CLASSES`, `FORBIDDEN`, guard, tool stubs, moved helpers | | | |
| `test/contract.bats` | counts (4.3) | | | |
| `test/net.bats`, `test/lint.bats`, `test/lint-repo.bash` | NFR6 region | | | |
| `test/files.bats`, `test/timeout.bats` | helpers move out | | | |
| `README.md` | class lines, verb line | | full text (section 7) | |
| `skills/lendk/SKILL.md` | verb line, class row | | full text | |
| `skills/lendk/references/setup.md`, `.claude/CLAUDE.md` | | | text | |
| `test/readme.bats`, `test/skill.bats` | | | FR37, FR38 topics | |
| `CHANGELOG.md` | | | Unreleased entry | 1.1.0 entry |
| `docs/release.md` | | | | new steps |

## 4. Test strategy

### 4.1 Harness

- `upgrade.bats` never runs `upgrade` on the working tree. `setup` copies `bin/lendk` to `$HOME/.local/bin/lendk`, mode 0755, and points `LENDK` at the copy; `teardown` compares the working tree's `bin/lendk` with a checksum taken in `setup_file`. `run_lendk` in `common.bash` refuses `upgrade` when `LENDK` is the working tree's file, so no other test file can do it either.
- `sandbox` puts `curl` and `wget` stubs that exit 7 in `$SB/bin`, so no test reaches the network; `upgrade.bats` replaces them where a test needs a download.
- Releases are fixtures in `make dist`'s layout, built in `setup_file` without git, so the file also runs in the busybox image: `release NAME VERSION` writes `lendk-VERSION/bin/lendk` (the working tree's file with its `LENDK_VERSION` line rewritten) plus `LICENSE` and `skills/`, packs it with `tar` and `gzip` into `$REL/NAME/latest/download/lendk.tar.gz`, and writes `SHA256SUMS` in `sha256sum`'s format. Standard releases: `new` (99.0.0), `same` (the tree's version), `old` (0.0.1). A test that needs a broken release copies `new` and changes one thing. Only T21 builds real `make dist` releases, and needs git and make.
- A `file://` base is `LENDK_INSTALL_BASE_URL=file://$REL/NAME`. An `https://` base is `https://releases.test/NAME` with a stub `curl` or `wget` that copies `$REL/NAME/...` to its output argument and records its arguments, environment and PID under `$STUB_LOG`.
- Kill and expiry tests export `LENDK_TEST_FAMILY=$SENTINEL` and use `family`, `none_within` and `gone` from `common.bash`. `snapshot` (from `files.bats`) and `timed_lendk` and `within` (from `timeout.bats`) move to `common.bash`, unchanged.
- "Changes nothing" in the table below means: lendk's checksum and inode are the same, TMPDIR is empty, lendk's directory holds only `lendk`, and stderr is the exact line.
- Tests that need an unwritable directory skip as root.

### 4.2 Tests

| Code | Test name | Observes |
|---|---|---|
| T1 | `FR45, NFR5: upgrade replaces lendk with the latest release and touches nothing else` | exit 0; stdout is `upgraded lendk V to 99.0.0 at PATH`; the file equals the release's, mode 0755; `--version` prints 99.0.0; the snapshot differs only in lendk's file and the shim directory; changes nothing else; zero mock calls |
| T2 | `FR45: an argument is usage, stdin is never read, and a terminal changes only the FIX` | `upgrade x` gives `usage`; a line piped to stdin is still there afterwards; a refusal under `LENDK_PROMPT=allow` and `never` differs only in the FIX |
| T3 | `FR46: an https base goes through curl with https-only options` | the stub's two argument lines: `-fsSL --proto =https --tlsv1.2 -o FILE URL` for both assets |
| T4 | `FR46: without curl, wget downloads, with --https-only where it has it` | two wget stubs, one whose `--help` lists the option |
| T5 | `FR46: a base that is not https:// or file:///, or holds a blank, is usage, and a set base is named in a notice` | `http://`, `ftp://`, `file://relative`, a value with a space; the notice line on a valid base |
| T6 | `FR46, NFR4: a missing tool is upgrade before anything is fetched, and a file base needs no curl or wget` | PATH holding bash and all tools but one; changes nothing |
| T7 | `FR46: a mapped curl runs without its shim and gets no key, and the tools' output stays out` | `curl` mapped to K1 with its shim first on PATH; zero mock calls; the stub's PATH lacks the shim directory; a noisy stub adds no line |
| T8 | `FR47: a failed download and one cut short change nothing` | stub exits 22; stub writes half the archive and exits 0 |
| T9 | `FR47: another checksum, or SHA256SUMS without the asset, changes nothing` | `lists nothing` for the second |
| T10 | `FR47: an archive without lendk, or holding a file that is not lendk, changes nothing` | no `bin/lendk`; a `bin/lendk` without the second line |
| T11 | `FR47: a lendk that does not run under this bash changes nothing` | a `bin/lendk` with the second line that exits 125 |
| T12 | `FR47: a release that is not newer is up to date, also for an install ahead of it, compared number by number` | `same` and `old`, exit 0, the stdout line; a 9.0.0 copy against 10.0.0 upgrades, a 10.0.0 copy against 9.9.9 does not |
| T13 | `FR48: a symlinked lendk is refused before any fetch` | the logging stub was not called; the target file is unchanged |
| T14 | `FR48: a file that is not lendk's, or a directory the user cannot write, is refused before any fetch` | a copy with another second line; `chmod 555` on its directory |
| T15 | `FR49: the upgrade is a rename: a new inode, and an open descriptor keeps the old bytes` | as `install.bats` does for `make install` |
| T16 | `FR49: two upgrades at once, and add calls alongside, all succeed and leave one whole file` | two `upgrade` and five `add` calls started together: every exit 0, five entries, the release's file, no staged file, no lock |
| T17 | `FR49: sync runs through the new file, and with an invalid map line the upgrade stands` | a mapped command without a shim gets its shim; with a bad line: the `upgraded` line, `sync`'s `map` line, exit 125, `--version` prints 99.0.0 |
| T18 | `FR50: a download that never returns gives upgrade after LENDK_TIMEOUT and before LENDK_TIMEOUT + 2 s` | a sleeping stub and one that ignores TERM, `LENDK_TIMEOUT=2`; the exact line; `within 2 4`; changes nothing; the stub is gone |
| T19 | `FR50: TERM, INT, HUP or KILL during the fetch leaves no tool, watchdog, temporary directory or staged file` | to lendk and to its process group; `none_within 2`; changes nothing |
| T20 | `FR50, NFR5: KILL between staging and the rename removes the staged file and keeps lendk` | `LENDK_TEST_PAUSE` holds lendk before the rename; KILL; within 2 s the staged file and the temporary directory are gone |
| T21 | `AC7: install.sh, then upgrade, against make dist releases` | AC7 as written; needs git and make |
| T22 | `NFR6: no verb connects to an internet address` (`net.bats`, extended) | adds `upgrade` from a `file://` base, on a sandbox copy |
| T23 | `NFR6: the source names curl and wget only in the network region, and no nc or /dev/tcp` (`net.bats`, replaces the third test) | one begin and one end marker; no hit outside them |
| T24 | `NFR6: lint-repo.bash allows curl and wget only in the network region` (`lint.bats`) | a scratch copy with the names planted inside the region gives no region line; planted outside, it gives one |

`messages.bats` covers the three class rows in both modes without a change, since it walks the class table.

### 4.3 Counts in `contract.bats`

| Assertion | 1.0 | 1.1 |
|---|---|---|
| verb lines of PRD 4.1 | 8 | 9 |
| classes of PRD 5.3 | 15 | 16 |
| FIX texts of PRD 5.3 | 21 | 24 |
| list and class lines of `--help` that the README repeats | 28 | 31 |
| variables of PRD section 8 | 10 | 11 |

### 4.4 Failure modes

| Failure | Outcome | Requirement | Test |
|---|---|---|---|
| Download fails or is cut short | `upgrade`, nothing changed | FR47 | T8 |
| Checksum mismatch, or no sum listed | `upgrade`, nothing changed | FR47 | T9 |
| Archive without lendk | `upgrade`, nothing changed | FR47 | T10 |
| New lendk does not run under this bash | `upgrade`, nothing changed | FR47 | T11 |
| The running file is replaced while bash reads it | a rename, so the old process keeps the old file | FR49 | T15 |
| A concurrent `lendk add`, or a second `upgrade` | all succeed; the rename is atomic and `sync` holds the lock | FR49 | T16 |
| A download that hangs | `upgrade` within `LENDK_TIMEOUT` + 2 s, no process left | FR50 | T18 |
| lendk killed during the fetch or before the rename | nothing left behind, lendk unchanged | FR50, NFR5 | T19, T20 |
| Read-only install | refused before any fetch | FR48 | T14 |
| Foreign file under lendk's name | refused before any fetch | FR48 | T14 |
| Symlinked install | refused before any fetch | FR48 | T13 |
| Install ahead of the latest release | up to date, exit 0, nothing changed | FR47 | T12 |
| `sync` fails after the rename | the upgrade stands; `sync`'s own lines and status | FR49 | T17 |
| `LENDK_INSTALL_BASE_URL` not `https://` or `file:///` | `usage`, nothing fetched; a valid set base is named in a notice | FR46 | T5 |
| A needed tool is missing | `upgrade`, nothing fetched | FR46 | T6 |
| `curl` or `tar` is a mapped command | the real tool runs, no key is read | FR46 | T7 |

## 5. Stages

Sizes: S fits a short pass, M a full one.

### S1 The verb, without the time bound (M)

- `bin/lendk` tables:
  - verb line, after `init`: `lendk upgrade                                  # replace lendk with the latest release, then sync`
  - class rows, after `write`:
    - `upgrade|125|Retry; on a slow connection raise LENDK_TIMEOUT.|$stop_fix`
    - `upgrade:install|125|Upgrade lendk the way it was installed.|$stop_fix`
    - `upgrade:local|125|Fix it, then run: lendk upgrade|$stop_fix`
  - variable row `LENDK_INSTALL_BASE_URL|release base for upgrade and install.sh, https:// or file:///; default https://github.com/v-bonilla/lendk/releases`; the `LENDK_TIMEOUT` row also names `upgrade`'s fetch; the name column of `--help` widens to 22 characters.
- `upgrade_verb`, dispatched from `main`, following I1 to I5, I7 and I9 to I11. The fetch is one function that reports through the temporary directory and runs in a plain subshell, so S2 turns that call into the job without rewriting it. The temporary directory and the staged file are removed on every exit path; the kill paths come with S2.
- The network region (I4), the lint check and T22 to T24.
- `common.bash`: `upgrade` in `CLASSES`, `lendk upgrade` in `FORBIDDEN`, the guard and the tool stubs of 4.1, the moved helpers.
- `contract.bats` counts; in `README.md` the three class lines as `--help` prints them and the verb line in the Daily use block; in `SKILL.md` the verb line and one `upgrade` row, exit 125.
- Done: `test/lib/bats-core/bin/bats test/upgrade.bats test/contract.bats test/skill.bats test/messages.bats test/cli.bats test/net.bats test/files.bats test/timeout.bats test/harness.bats` passes with T1 to T17 present; `bash test/lint-repo.bash` prints exactly `lint-repo: FR50: in no test name`; shellcheck has zero findings. Expected failures: the `lint.bats` tests that expect a clean lint of the repository or of a scratch copy.

### S2 Time bound, signals, cleanup (M)

- The fetch becomes the job J under the watchdog W (I6); the staged file's removal joins `watchdog` and `watchdog_rescue` (I8); T18 to T21.
- Done: `make check` exits 0; `make check-docker` exits 0, with `upgrade.bats`, `timeout.bats` and `signals.bats` passing in both images; `make bench` exits 0.

### S3 Documentation (S)

- Section 7 in full, the FR37 and FR38 topics in `readme.bats` and `skill.bats`, the CHANGELOG entry under Unreleased.
- Done: `test/lib/bats-core/bin/bats test/readme.bats test/skill.bats test/contract.bats test/lint.bats` passes; `grep -rn 'no network access' README.md skills .claude/CLAUDE.md` prints nothing, and every sentence about network use in those files holds under NFR6.

### S4 Release preparation (S)

- `LENDK_VERSION=1.1.0` in `bin/lendk`.
- `CHANGELOG.md`: the Unreleased entries move under `## [1.1.0] - YYYY-MM-DD` with the release date; the comparison links gain 1.1.0.
- `docs/release.md` gains three things: before the commit step, "delete `docs/plan.md` when the release had one"; in the release step, `lendk upgrade` reads the same `releases/latest/download/` assets as `install.sh`; after the installer check, a check of the verb against the published release, in a scratch HOME that the installer filled: `lendk upgrade` prints `lendk X.Y.Z is up to date: the latest release is X.Y.Z`. That check is the only run of the real download path, since the suite stubs the tools.
- The three gates of `docs/release.md`: `make check`, `make check-docker`, `make bench`, each exit 0.
- Done: `bin/lendk --version` prints `lendk 1.1.0`; the three gates exit 0; `docs/release.md` holds the three additions. The release commit, which deletes this file, the tag, the push and the GitHub release are the maintainer's.

## 6. Implementation rules

- I1 Placement. All `upgrade` code sits after the `run` dispatch, so a shim never parses it (NFR1). Before the dispatch only the three class rows and the watchdog's staged-file line are added. `bin/lendk` stays one file (NFR7).
- I2 Order in `upgrade_verb`: arguments (`usage`); the base and its validation (`usage`, the value printed with non-printing characters replaced); `set_self` and the FR48 checks, in the order symlink, regular file with lendk's second line, writable directory; the tools; the notice for a set base; the temporary directory and the staged file; the fetch; the outcome. Nothing is created before the FR48 checks and the tool check pass.
- I3 lendk's second line is a constant in the `upgrade` code. T1 fails if it differs from the file's own second line, since the copy would refuse itself.
- I4 Network region. One function, `upgrade_download URL OUT`, sits between `# lint: network begin` and `# lint: network end`, with the lookup of the download tool and the text that names it. It mirrors `fetch` of `install.sh`. No other line of `bin/lendk`, comments and tables included, names `curl` or `wget`. `test/lint-repo.bash` marks the region as it marks the tables, reports either name outside it, and reports `nc` in command position or `/dev/tcp` anywhere.
- I5 Tools. They are found on, and run with, the PATH that `allow_env` builds, without the shim directory. curl or wget is looked up only for an `https://` base. The tools keep the caller's environment otherwise, with stdin `/dev/null` and their output in the temporary directory.
- I6 Job model, as `read_values` does it for the backend, without the terminal handoff:
  - lendk traps TERM, INT and HUP with `backend_signal`, turns job control on, starts W as `{ (watchdog) || watchdog_rescue; } </dev/null >/dev/null 2>&1 &`, starts J as a background subshell, waits with plain `wait` in a loop until J is gone, and turns job control off. Between `set -m` and `set +m` only builtins run.
  - J traps TERM, INT and HUP to exit, sets umask 077, records its PID in `$lendk_tmp/pid`, downloads, verifies, and writes one result line: `ok X.Y.Z`, `same X.Y.Z`, or `fail FORM TEXT`.
  - After J: a `timeout` mark is the expiry line; `fail` is its line; `same` prints the up-to-date line; `ok` goes on to the rename. The rename runs after `set +m` and before W is stopped, so a KILL at any moment still finds W alive to clean up. Then lendk stops W, removes the temporary directory and resets its traps.
  - `LENDK_TEST_PAUSE` holds lendk just before the rename, for T20.
  - Measured on a prototype of this model built from `bin/lendk`'s own `watchdog`, with `LENDK_TIMEOUT=2`:

    | bash | Hung tool | Tool ignoring TERM | TERM, INT, HUP, KILL to lendk | KILL before the rename |
    |---|---|---|---|---|
    | 5.2.37, GNU | 2.16 s | 2.37 s | nothing left after 1.5 s | staged file and temporary directory gone after 1.5 s |
    | 4.4.23, busybox | 2 to 3 s | 2 to 3 s | nothing left after 1.5 s | staged file and temporary directory gone after 1.5 s |
- I7 Temporary files. The temporary directory holds the two assets, the archive listing, the one extracted file, the result and the job's own files, each 0600. The member is found with `gzip -dc ARCHIVE | tar -tf -`, filtered to exactly one `lendk-N.N.N/bin/lendk`, and read with `gzip -dc ARCHIVE | tar -xOf - MEMBER`: nothing else of the archive is written anywhere. GNU tar and busybox tar both do this; bsdtar is checked by the macOS job. The extracted file runs as `"$BASH" FILE --version` with stdin `/dev/null`, so a TMPDIR mounted noexec does not matter.
- I8 Staged file. lendk creates it with `mktemp DIR/.lendk.XXXXXX` before W starts, so W knows its name; J fills it and sets mode 0755 only for a higher version; lendk renames it or removes it. `watchdog` and `watchdog_rescue` remove it with the temporary directory when lendk is gone. With no staged file set, their behavior for `run` and `unlock` is unchanged.
- I9 Versions compare as three base-10 numbers, taken from an output that is exactly `lendk N.N.N`.
- I10 After the rename lendk prints the `upgraded` line and runs `exec "$self" sync`. No other lendk code runs after the rename.
- I11 Messages carry the exact TEXT of PRD 5.3. No TEXT holds a period followed by a space.

## 7. Documentation to sync (S3)

| File | Change |
|---|---|
| `README.md`, `## Contents` | an entry for `## Upgrade` |
| `README.md`, `## Key features` | the bullet on network use says, in plain words, that only `lendk upgrade` uses the network, and only when you run it |
| `README.md`, `## Upgrade` (new, between `## Installation` and `## Uninstall`) | `lendk upgrade`; what it does: latest release, checksum, one file replaced by a rename, then `sync`; what it leaves alone; rerun the installer to refresh PATH setup or a skill copy (`--skill-dir`), or to pick a release (`--version`); when it refuses; the tools it needs; `LENDK_TIMEOUT`; `LENDK_INSTALL_BASE_URL` and what it trusts; lendk 1.0.0 has no `upgrade`, so it moves up by rerunning the installer once; from a checkout, `git pull` then `make install`, a sentence that moves here from `#### From source` |
| `README.md`, `## Daily use` | the verb line (S1) |
| `README.md`, `## How it works` | the bullet on network use and on what lendk writes matches NFR5 and NFR6 |
| `README.md`, `### Security model` | one bullet: what `upgrade` trusts and what the checksum does not catch |
| `README.md`, `## Troubleshooting` | the class lines (S1); one line on `upgrade`: lendk is unchanged, read the TEXT |
| `README.md`, `## Agent contract` | a bullet: run `lendk upgrade` only when the user asks, and never set `LENDK_INSTALL_BASE_URL`. The sentence that `readme.bats` pins stays word for word |
| `README.md`, `## Requirements` | tar, gzip, `sha256sum` or `shasum`, and curl or wget, for `lendk upgrade` only |
| `skills/lendk/SKILL.md` | the description names upgrading; verbs and an example; the `upgrade` row: stop and ask the user, lendk itself is unchanged; a hard rule as in the agent contract; a common question on upgrading, saying the skill copy stays as it is and how to refresh it |
| `skills/lendk/references/setup.md` | an `## Upgrade` section; the title names it |
| `.claude/CLAUDE.md` | where it states the network rule or the lint regions, the text matches NFR6 and I4 |
| `CHANGELOG.md` | Added: `lendk upgrade`, the `upgrade` class, `LENDK_INSTALL_BASE_URL` in lendk. Changed: lendk uses the network in `lendk upgrade` only; no other verb does |
| `test/readme.bats` | the FR37 topics: `## Upgrade` between `## Installation` and `## Uninstall`, `lendk upgrade`, `LENDK_INSTALL_BASE_URL`, `--skill-dir`, `only when the user asks` |
| `test/skill.bats` | FR38: the skill names `--skill-dir` as the way to refresh its copy |

## 8. Risks

- R1 A test runs `upgrade` on the working tree's `bin/lendk` and replaces it, or reaches GitHub. Mitigation: the guard in `run_lendk`, the checksum in `teardown`, and the failing `curl` and `wget` stubs in every sandbox (4.1).
- R2 The watchdog change breaks FR16 or FR17. Mitigation: I8 adds one conditional removal and nothing else; `timeout.bats` and `signals.bats` run in both images at S2.
- R3 An external command between `set -m` and `set +m` takes the terminal and stops lendk in a background job. Mitigation: I6 runs the rename after `set +m`; T19 and T20 start lendk as a job.
- R4 The lint exemption hides network code. Mitigation: the region holds one function; T23 counts the markers; T24 plants names on both sides.
- R5 Shim overhead grows. Mitigation: I1; `make bench` at S2 and S4.
- R6 `tar -xOf` or `tar -tf` differs on bsdtar. Mitigation: the macOS job on the release tag, which `docs/release.md` waits for; a failure there blocks the release.
- R7 The suite never downloads from GitHub. Mitigation: the `docs/release.md` check of S4, which needs the release assets to be public.
- R8 FR37 conflicts on the rebase. Mitigation: the rule in section 1.
- R9 A count in 4.3 drifts from the PRD. Mitigation: `contract.bats` derives each count from the PRD and fails on any difference.
- R10 The new file runs under the bash that ran `upgrade` but not under the first bash on PATH. Mitigation: I10 runs `sync` through the file's own first line, as shims do, so an `unsupported` line shows at once.
- R11 A skill copy stays at the old version after `upgrade`. Mitigation: the README and the skill say how to refresh it; lendk keeps no record of where a copy lives.
