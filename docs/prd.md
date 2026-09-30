# lend product requirements, v1

lend gives API keys stored in `pass` to the commands that need them, only while they run. The user types `gh`; `gh` gets `GH_TOKEN`; nothing else does.

## 1. Problem

The common habit, `export OPENAI_API_KEY=...` in a shell rc file, gives every key to every process.

| Habit | Where the key leaks |
|---|---|
| `export KEY=...` in rc | Every process: install scripts, build tools, AI agents that log their environment, crash reporters. The plaintext file reaches dotfile repos. |
| `env KEY=$(pass show ...) cmd` | argv, visible to all local users in `ps` |
| Alias or shell function | No leak, but scripts, subprocesses and agents run the bare command and fail |
| `.env` or direnv | Every process in that directory |
| Prefix command (`x run -- cmd`) | No leak, but humans forget it and agents never know it |

`pass` fixes storage at rest, not delivery.

## 2. Users and jobs to be done

Human who uses pass and GnuPG, on Linux first:
- H1 Type `gh` and have it work, while no other process sees `GH_TOKEN`.
- H2 Give a new tool its keys in one command.
- H3 Rotate a key in one place, with no follow-up step.
- H4 See which command gets which key, and what is broken.
- H5 Run a script once with specific keys.

AI coding agent running shell commands as the human's user, without a terminal:
- A1 Run the same commands with the same syntax.
- A2 Never hang on an unseen passphrase prompt; get a distinct exit code and a message to relay.
- A3 Diagnose failures without seeing a secret value.

## 3. Goals, non-goals, security model

Goals:
- G1 Per-command least privilege with no prefix: every caller that finds a mapped command through PATH gets its keys.
- G2 Deterministic, non-interactive behavior for callers without a terminal.
- G3 Setup in five minutes; no state beyond the map and the shims.
- G4 Install and uninstall without root, fully reversible.

Non-goals for v1: sandboxing; writing to the store; other backends; store paths other than `PREFIX/KEY` (migrate with `pass mv`); multi-line values; per-directory scoping; fish; Windows; daemons or value caches; packaging beyond `make install`.

Protects against: ambient exposure (keys reach only mapped commands, `run` targets and their descendants); plaintext keys in rc files; keys in argv; agents hanging on prompts.

Does not protect against:
- Same-user processes. While gpg-agent holds the passphrase, any of them, an AI agent included, can run `pass show`, read `/proc/PID/environ` of a running mapped command, or edit the map, shims or PATH. lend keeps keys out of an agent's context by default; it does not stop an agent that decides to fetch them.
- Children of mapped commands (`terraform` providers, git under `gh`), and root.
- Callers that bypass PATH (absolute paths, `npx`, `npm run`, `uv run`, services): they run without keys and fail closed.

## 4. User experience

### 4.1 Verbs

Each comment says why the verb exists; behavior is in FR1 to FR30.

```
lend run [KEY|@GROUP...] -- CMD [ARG...]  # cron, git helpers, one-offs; shims call it
lend run KEY|@GROUP...                    # subshell with keys; replaces load/unload
lend add CMD|@GROUP KEY|@GROUP...         # the one setup step: map, then sync
lend rm CMD|@GROUP [KEY|@GROUP...]        # undo add, then sync
lend check [NAME...]                      # diagnose without decrypting; replaces who
lend sync                                 # shims after hand edits or a dotfile checkout
lend unlock [KEY|@GROUP...]               # the fix agents ask for; a lock probe
lend init bash|zsh                        # one rc line that upgrades with the tool
lend --help | --version
```

No verb takes flags. Cut: `who`; `load`/`unload` (the subshell has bounded scope, needs no shell function and no `eval` of secret-bearing output), and with them `expand`; an internal `shim` verb; `lock` (equals `gpgconf --reload gpg-agent`); `ls`, `edit` (the map is a plain file).

### 4.2 Map file

```
# ~/.config/lend/map
@aws        AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
gh          GH_TOKEN
terraform   @aws CLOUDFLARE_API_TOKEN    # trailing comment
```

- One entry per line; fields split on blanks; `#` starts a comment anywhere; blank lines are ignored.
- `@NAME KEY...` defines a group. NAME matches `[A-Za-z0-9_-]+`. Groups hold keys only.
- `CMD WORD...` maps a command. CMD matches `[A-Za-z0-9._+-]+`, does not start with `-`, and is not reserved: `lend pass gpg gpg2 gpg-agent gpgconf bash sh env` (these recurse or reach every script). WORD is a KEY or `@NAME`.
- KEY matches `[A-Za-z_][A-Za-z0-9_]*`; its value is the first line of store entry `PREFIX/KEY`.
- Each CMD and group appears once; a group may be used before its definition.
- Expansion follows word order, inlines groups, and drops duplicates, keeping the first.

### 4.3 Shell integration

Last line of `~/.bashrc` or `~/.zshrc`:

```
eval "$(lend init bash)"      # or: lend init zsh
```

It puts the shim directory first on PATH and re-asserts that before every prompt, so version managers and virtualenvs cannot shadow shims in interactive shells. Real binaries still resolve in PATH order, so a virtualenv's `llm` is the one that runs.

### 4.4 Sessions

S1 First-time setup:
```
$ make install                        # one file: ~/.local/bin/lend
$ echo 'eval "$(lend init bash)"' >> ~/.bashrc; exec bash
$ pass insert env/GH_TOKEN
$ lend add gh GH_TOKEN
gh	GH_TOKEN	set in environment: GH_TOKEN (delete its export from shell startup files)
$ # delete the old export, exec bash
$ gh repo list                        # works; the shell has no GH_TOKEN
```

S2 Adding a tool:
```
$ lend add @aws AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
$ lend add terraform @aws CLOUDFLARE_API_TOKEN
terraform	AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLOUDFLARE_API_TOKEN	missing key: CLOUDFLARE_API_TOKEN (pass insert env/CLOUDFLARE_API_TOKEN)
$ pass insert env/CLOUDFLARE_API_TOKEN; terraform plan
```

S3 Rotating a key. Every call reads the store, so nothing needs a resync:
```
$ pass insert -f env/OPENAI_API_KEY
$ lend check OPENAI_API_KEY       # which tools to retest
...
aider	OPENAI_API_KEY	ok
llm	OPENAI_API_KEY	ok
```

S4 One-off run, subshell, git helper:
```
$ lend run OPENAI_API_KEY -- python eval.py
$ lend run @aws
lend: notice: subshell with AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; exit to drop them
$ aws s3 ls; exit
$ git config --global credential.https://github.com.helper '!lend run -- gh auth git-credential'
```

S5 Cold cache, human: pinentry asks once, then `gh` runs. Each decrypt still re-runs the key's KDF, since gpg-agent caches the passphrase, not the key: 0.5 to 0.95 s by default, about 40 ms after the README's `s2k-count` tuning.

S6 Agent hits a locked store:
```
$ gh pr list                          # agent, no terminal
lend: locked: env/GH_TOKEN needs the gpg passphrase and this caller cannot prompt. Ask the user to run 'lend unlock' in a terminal, then retry.
$ echo $?
120
```
The agent relays the message and waits. `lend unlock </dev/null` (0 warm, 120 cold) lets it probe first.

S7 Shadowed shim, under an agent harness that prepends its own bin directory:
```
$ gh pr list                          # ran without GH_TOKEN, failed
$ lend check gh
...
gh	GH_TOKEN	shadowed by /opt/harness/bin/gh (put the shim dir first on PATH, or use: lend run -- gh)
$ lend run -- gh pr list          # works
```

## 5. Agent contract

### 5.1 Non-interactive rule

A call is interactive when `LEND_PROMPT=allow`, or when `LEND_PROMPT` is unset or `auto` and stdin or stderr is a terminal. `never` is never interactive; other values exit 2. Harnesses that give agents a pseudo-terminal set `LEND_PROMPT=never`.

Testing stderr keeps git credential helpers interactive (stdin is a pipe, stderr the terminal). Probing `/dev/tty` is rejected: agents launched from a terminal still have one, and a curses pinentry would seize it.

### 5.2 Fail fast on a locked gpg-agent

Every backend call appends a `--status-fd` to `PASSWORD_STORE_GPG_OPTS`, after the user's value; non-interactive calls also append `--pinentry-mode error`. Evaluated with GnuPG 2.4, pass 1.7.4 and a `pinentry-program` that records launches:

| Variant | Cold cache | Decision |
|---|---|---|
| `--pinentry-mode error` | exit 2 in about 30 ms, status `ERROR pkdecrypt_failed 67108949` (code 85, No pinentry), no pinentry launch; warm cache decrypts | adopted |
| `--batch` alone | pinentry launched | rejected |
| `--pinentry-mode cancel` | code 99 (Canceled), same as a user pressing Cancel | rejected |
| gpg-agent `KEYINFO` probe | needs a store-to-keygrip mapping | rejected |

Classification reads status codes, never translated text. Codes 85 and 99 exit 120, so an interactive Cancel also reads as locked; anything else exits 125, class `decrypt`. FR12 verifies this on GnuPG 2.2 and 2.4.

### 5.3 Exit codes and stderr

Before exec, every stderr line is `lend: CLASS: TEXT`, and every error ends with the next command to run; backend stderr is captured and summarized as `decrypt` TEXT. `env` stands for the configured prefix. Codes 120 and 125 to 127 avoid the low codes tools commonly use; other codes are the target's own. `notice` lines are not errors.

| Code | CLASS | Pattern after `lend: CLASS: ` |
|---|---|---|
| 0 | | success |
| 1 | | `check` found a problem |
| 2 | `usage` | `TEXT. See: lend --help` |
| 120 | `locked` | `env/KEY needs the gpg passphrase and this caller cannot prompt. Ask the user to run 'lend unlock' in a terminal, then retry.` |
| 125 | `map` | `MAP:LINE: TEXT. Fix the line, then run: lend check` or `CMD is not mapped. Map it: lend add CMD KEY..., or name keys: lend run KEY... -- CMD` |
| 125 | `missing key` | `env/KEY is not in the store. Add it: pass insert env/KEY` |
| 125 | `decrypt` | `env/KEY: TEXT. See gpg's error in a terminal: lend unlock KEY` |
| 125 | `write` | `PATH: TEXT. Fix it, then run: lend sync` |
| 126 | `exec` | `PATH is not executable. Fix it, or unmap it: lend rm CMD` |
| 127 | `not found` | `CMD is not on PATH outside DIR. Install it, or unmap it: lend rm CMD` |

### 5.4 Secret values

No verb writes a value to stdout, stderr, a file, or any process's argv. Values live only in lend's memory, the backend pipe, and the target's environment (FR14).

## 6. Functional requirements

Each FR has a bats test named with its ID; `pass` is a call-logging mock unless stated.

Injection (`run` and shims):
- FR1 The target's environment equals the caller's plus the injected keys (`env -0` diff).
- FR2 A key with a non-empty value in the caller's environment is not decrypted and keeps its value.
- FR3 Order: parse, read the map if needed, resolve CMD, confirm all keys to decrypt exist, decrypt, exec. Any failure exits before CMD starts; a missing-key error lists every missing key.
- FR4 CMD containing `/` is used as given; otherwise the first executable regular file named CMD on PATH, skipping entries that canonicalize to the shim directory and files whose canonical path lies inside it.
- FR5 lend `exec`s the target: argv0 as given, arguments unchanged, the target's own status and signals (status 7 propagates; SIGTERM reaches it).
- FR6 The target gets the caller's PATH; lend's own children run with the shim directory removed.
- FR7 A value is the entry's first line without its newline; an empty first line is a `missing key` error.
- FR8 Named keys replace the map entry. Without keys, `run -- CMD` uses the entry for CMD's basename; unmapped exits 125.
- FR9 `run KEY...` without `--` prints one `notice` naming the keys, then execs `$SHELL` (else `/bin/sh`) with the keys and `LEND_SUBSHELL` holding their names. Non-terminal stdin exits 2.

Agent contract:
- FR10 Interactivity follows 5.1 (matrix over terminal stdin and stderr via `script`, and each `LEND_PROMPT` value).
- FR11 Non-interactive backend calls add `--pinentry-mode error` after the user's `PASSWORD_STORE_GPG_OPTS`, otherwise preserved.
- FR12 Real GnuPG, temporary `GNUPGHOME`, passphrase-protected key, recording `pinentry-program`: a cold non-interactive call exits 120 within 2 s, recorder not launched; after priming via loopback it exits 0; with `LEND_PROMPT=allow` the recorder launches.
- FR13 Every stderr line before exec matches a 5.3 pattern; no backend line passes through.
- FR14 With a sentinel value in the store, no test's stdout or stderr, no file under the test HOME or TMPDIR, and no argv under `strace -f -e execve` contains it. lend runs `set +x +v` before reading values, so `bash -x` and an exported `SHELLOPTS=xtrace` expose nothing.
- FR15 lend never reads stdin; only the FR9 subshell and, in interactive calls, pinentry face the user.

Map editing:
- FR16 A map violating 4.2 makes `add`, `rm`, `sync`, and `run` or `unlock` calls that read it, exit 125 citing `MAP:LINE`.
- FR17 `add NAME WORD...` creates the entry or appends absent words in order. `rm NAME` removes the entry and its shim; `rm NAME WORD...` removes those words, and the entry when none remain.
- FR18 `add` and `rm` validate first and change nothing on error: invalid names, and groups inside groups, exit 2; an unknown group, or removing a referenced group, exits 125 naming the cause. Removing an absent name or word exits 0 with a `notice`.
- FR19 Map writes change only the affected line or append one. They are atomic (temporary file beside the target, then rename), follow a symlinked map to its target, and create a new map with mode 0600 in a 0700 directory.
- FR20 `add` and `rm` run `sync`, then print the affected rows and any `# problem:` lines in `check` format without path lines; they exit 0 when the write and sync succeed.

Shims:
- FR21 `sync` writes one shim per mapped command, mode 0755, with lend's canonical path shell-quoted:
  ```
  #!/bin/sh
  # lend shim v1: generated by lend sync, edits are overwritten
  exec '/home/alice/.local/bin/lend' run -- 'gh' "$@"
  ```
- FR22 `sync` deletes only files whose second line starts with `# lend shim `, removing those of unmapped commands. A foreign file named like a mapped command stays untouched and yields a `write` error (exit 125) after the other shims are written.
- FR23 A second `sync` leaves every file byte-identical and prints the same `N shims in DIR`.

`check`:
- FR24 `check` never calls the backend read (zero mock calls); it tests entries by file existence.
- FR25 Stdout: `# map`, `# shims`, `# store` lines; `# problem: TEXT (FIX)` lines; then groups and commands, each sorted by name, as `NAME<TAB>KEYS<TAB>STATUS`, STATUS being `ok` or `; `-joined problems with fixes in parentheses. `check NAME...` keeps rows named NAME, holding key NAME, or referencing group NAME.
- FR26 Detects: map violations; missing key; command not found; no shim; stale shim (differs from FR21); stray shim; shim directory not on PATH; shadowed, naming the earlier path; a mapped key set in the environment and absent from `LEND_SUBSHELL`.
- FR27 `check` exits 1 when anything shown has a problem, else 0.

`unlock`, `init`, help, docs:
- FR28 `unlock` decrypts each named key (default: first mapped key present), discards values, prints `unlocked`, and follows `run`'s interactivity and exit rules; no mapped key present exits 125.
- FR29 `init` output moves the shim directory to the front of PATH without duplicates, and repeats that plus a command-hash reset (`hash -r`, `rehash`) before every prompt, registered once even if sourced twice (bash and zsh tests). It reads no map.
- FR30 `--help` prints verbs, map grammar, exit codes and environment variables, exit 0; `--version` prints `lend X.Y.Z`; no arguments or an unknown verb print usage on stderr, exit 2.
- FR31 The README covers the security model, s2k tuning, cache TTLs and flushing, `lend run` by absolute path in cron, systemd and MCP configs, the git credential helper, PATH-bypassing launchers, and an agent instruction block (on 120, stop and ask; never run `pass`).

## 7. Non-functional requirements

- NFR1 Latency: with keys preset and a 50-entry map, shim exec to target exec takes at most 15 ms median and 30 ms p95 on Linux x86_64 over 200 runs (`make bench`).
- NFR2 One backend read per key the caller did not set; none for verbs other than `run` and `unlock`.
- NFR3 Bash 4.4+. Linux is tier 1: releases need green CI on Ubuntu 22.04 (GnuPG 2.2), Ubuntu 24.04 (GnuPG 2.4) and the mock suite in a bash 4.4 container. macOS is tier 2: CI runs the suite with Homebrew bash; failures are tracked, not blocking. POSIX utility options only.
- NFR4 Runtime dependencies: bash, pass 1.7+, GnuPG 2.2+, POSIX utilities. Development: bats-core, shellcheck with zero findings.
- NFR5 lend writes only the map (`add`, `rm`) and the shim directory (`add`, `rm`, `sync`): no caches, logs or locks. Temporary files are mode 0600, never hold a value, and are gone before exit or exec.
- NFR6 No network: under `strace -f` the suite shows no AF_INET or AF_INET6 `connect`; the source has no `curl`, `wget`, `nc` or `/dev/tcp`.
- NFR7 One executable bash file. The backend is `backend_has KEY` and `backend_read KEY`; nothing else touches pass or the store.
- NFR8 Verbs, exit codes, stderr classes, map grammar and the shim call `run -- CMD` are stable within 1.x; upgrades need `sync` only if lend moves.
- NFR9 Repo: MIT license held by `v-bonilla`; no em-dashes, real keys, email addresses, or home paths other than `/home/alice`.

## 8. Files and configuration

| Item | Default | Override |
|---|---|---|
| Map | `${XDG_CONFIG_HOME:-~/.config}/lend/map` | `LEND_MAP` |
| Shims | `${XDG_DATA_HOME:-~/.local/share}/lend/shims` | `LEND_SHIMS` |
| Store | `~/.password-store` | `PASSWORD_STORE_DIR` |
| Entry prefix | `env` | `LEND_PREFIX` |
| Prompting | `auto` | `LEND_PROMPT`: `auto`, `never`, `allow` |

Relative XDG values are ignored. `PASSWORD_STORE_GPG_OPTS` is preserved. `SHELL` picks the subshell, which gets `LEND_SUBSHELL`. Cron, systemd and MCP configs skip rc files and need any overrides set too.

## 9. Install, upgrade, uninstall

- Install: `make install` copies one file to `$PREFIX/bin/lend` (`PREFIX` defaults to `$HOME/.local`; `DESTDIR` honored); copying it by hand is equivalent. Then the `init` line and `lend add`.
- Upgrade: replace the file; shims keep working (NFR8).
- Uninstall: delete the `init` line, then `make uninstall`: it removes marker-bearing shims, the shim directory if empty, and the installed file, and never touches the map, the store or rc files. Without the Makefile, delete the shim directory and the file. Mapped commands then run directly, without keys.

## 10. Maintenance model

No telemetry, no auto-update; `check` is the self-report.

| Drift | Effect | `check` reports |
|---|---|---|
| A new tool reorders PATH | runs without keys, fails | shadowed, or shim dir not on PATH |
| lend moved | shims exit 127 | stale shim; `sync` fixes |
| Real command removed | 127 | command not found |
| Key deleted or renamed | 125 | missing key |
| Map edited by hand | shims missing or stray | no shim, stray shim; `sync` fixes |
| Old `export KEY=` in rc | global leak overriding the store | set in environment |

The init hook heals PATH order in interactive shells. An expired cache gives agents 120 naming `lend unlock`. A GnuPG status-code change gives 125, never a hang, and fails FR12.

## 11. Alternatives considered

| Tool | Why not |
|---|---|
| gopass `env` | injects a whole subtree; prefix command; requires gopass |
| fnox, secretspec | project manifest plus `exec`/`run` prefix; agents must know it |
| CyberArk summon | `secrets.yml` per project plus prefix |
| Infisical `run` | server, account and network; prefix |
| OpenBao agent exec | server plus daemon, heavy for a laptop |
| direnv | every process in the directory gets the keys |
| sops `exec-env` | encrypted file plus prefix; no per-command map |
| Shell function wrappers | invisible to scripts, subprocesses and agents |

Only lend makes per-command least privilege the default with no prefix: PATH shims cover every caller, and pass stays the only store.

## 12. Acceptance criteria for v1

- [ ] AC1 CI green on Ubuntu 22.04, Ubuntu 24.04 and the bash 4.4 container; shellcheck clean.
- [ ] AC2 `test/` has a test for each of FR1 to FR31 and NFR1 to NFR9.
- [ ] AC3 FR12 passes on GnuPG 2.2 and 2.4; FR14 passes.
- [ ] AC4 `make bench` meets NFR1 on a Linux machine.
- [ ] AC5 Fresh HOME with a stub `gh`: after `make install`, `init`, `add gh GH_TOKEN`, the key reaches `gh` from an interactive shell, `bash -c`, Python `subprocess` and a nested shim (one decrypt), not the parent shell; `make uninstall` leaves only the map.
- [ ] AC6 Repo lint passes NFR9; the README has every FR31 topic.
- [ ] AC7 The macOS job has run; its result is recorded.

## 13. Open questions

- Q1 Command name. Default: at most 6 letters, no binary of that name in Debian, Homebrew or the AUR; fixed before the first commit.
- Q2 Hardware tokens that require a touch still block under `--pinentry-mode error`. Default: document it; no timeout in v1, since stock macOS lacks `timeout(1)`.
- Q3 `unlock` without arguments primes one recipient key; stores with per-folder `.gpg-id` files need `unlock KEY` per recipient. Default: accept and document.
