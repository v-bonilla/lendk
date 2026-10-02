# lendk product requirements, v1

lendk gives API keys stored in `pass` to the commands that need them, only while they run. The user types `gh`; `gh` gets `GH_TOKEN`; nothing else does.

## 1. Problem

The common habit, `export OPENAI_API_KEY=...` in a shell rc file, gives every key to every process, AI agents and install scripts included, and puts plaintext in dotfile repos. `env KEY=$(pass show ...) cmd` exposes the key in `ps`; aliases are invisible to scripts and agents; `.env` files and direnv reach every process in a directory; a prefix command (`x run -- cmd`) is forgotten by humans and unknown to agents. `pass` fixes storage at rest, not delivery.

## 2. Users and jobs to be done

Human who uses pass and GnuPG, on Linux first:
- H1 Type `gh` and have it work, while no other process sees `GH_TOKEN`.
- H2 Give a new tool its keys in one command.
- H3 Rotate a key in one place, with no follow-up step.
- H4 See which command gets which key, and what is broken.
- H5 Run a script once with specific keys.

AI coding agent running commands via `bash -c`, `zsh -c` or a login shell, with or without a pseudo-terminal:
- A1 Run the same commands with the same syntax.
- A2 Never wait on a prompt it cannot answer; get one `lendk: CLASS:` line that says what to relay.
- A3 Diagnose failures without seeing a secret value or being told to widen access.

## 3. Goals, non-goals, security model

Goals:
- G1 Per-command least privilege with no prefix: every process that finds a mapped command through PATH gets its keys, whether or not it read an rc file (4.3).
- G2 Bounded behavior without a terminal: a call spends at most `LENDK_TIMEOUT` + 2 s on backend work and cleanup, leaves no process behind, and reports every failure in one `lendk: CLASS:` line.
- G3 Setup in five commands (4.4); no state beyond the map and the shims.
- G4 Install and uninstall without root, fully reversible.

Non-goals for v1: sandboxing; writing to the store; other backends; store paths other than `PREFIX/KEY`; multi-line values; per-directory scoping; subshells holding keys; fish; Windows; daemons or value caches; packaging beyond `make install`; bash before 4.4 and GnuPG before 2.4, which get `unsupported` (FR22).

Protects against: ambient exposure (keys reach only mapped commands, `run` targets and their descendants); plaintext keys in rc files; keys in argv, in files, or in the environment of lendk's helpers; agents waiting on prompts.

Does not protect against:
- Same-user processes: while gpg-agent holds the passphrase, any of them, an AI agent included, can run `pass show`, read `/proc/PID/environ`, or edit the map, shims or PATH. lendk keeps keys out of an agent's context; it does not stop an agent that fetches them.
- Descendants of a mapped command, for their lifetime; root. A mapped shell, interpreter, launcher or agent CLI hands its keys to everything it runs, hence `--force` (4.2). Running processes keep old values after a rotation.
- Callers that bypass PATH (absolute paths, `npx`, `npm run`, `uv run`, services): they run without lendk's keys and fail, or act under the tool's own stored credentials (gh's `hosts.yml`, `~/.aws/credentials`).

Decrypt cost: gpg-agent caches the passphrase, not the unlocked key, so every decrypt re-runs the KDF, which by default can approach one second per key on slow machines. The README's tuning (`s2k-count 8388608`, then `gpg --passwd`) cuts that to tens of milliseconds but makes passphrase guessing about 20 times cheaper for anyone holding the secret key file: strong passphrases only. lendk never changes GnuPG settings.

## 4. User experience

### 4.1 Verbs

```
lendk run [KEY|@GROUP...] -- CMD [ARG...]      # exec CMD with its mapped or the named keys
lendk add [--force] CMD|@GROUP KEY|@GROUP...   # map, then sync
lendk rm CMD|@GROUP [KEY|@GROUP...]            # unmap, then sync
lendk check [NAME...]                          # diagnose without decrypting
lendk sync                                     # write shims to match the map
lendk unlock [KEY|@GROUP...]                   # unlock in a terminal; probe elsewhere
lendk init sh|bash|zsh|systemd                 # print PATH setup (4.3)
lendk --help | --version
```

`--force` is the only flag. Shims call `lendk run -- CMD`. After a hand edit of the map, run `lendk sync`. `gpgconf --reload gpg-agent` locks the store.

### 4.2 Map file

```
# ~/.config/lendk/map
@aws        AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
gh          GH_TOKEN
terraform   @aws CLOUDFLARE_API_TOKEN    # trailing comment
```

- One entry per line; fields split on blanks; `#` starts a comment anywhere; blank lines are ignored.
- `@NAME KEY...` defines a group of keys; NAME matches `[A-Za-z0-9_-]+`.
- `CMD WORD...` maps a command; WORD is a KEY or `@NAME`. CMD matches `[A-Za-z0-9_+][A-Za-z0-9._+-]*` and is not lendk's own runtime: `lendk bash pass gpg gpg2 gpg-agent gpgconf`.
- KEY matches `[A-Za-z_][A-Za-z0-9_]*`; its value is the first line of store entry `PREFIX/KEY`. Denied, as they steer lendk, pass, gpg, the shell or the loader, reach the backend (FR8), or bash rejects them: prefixes `BASH LENDK_ PASSWORD_STORE_ GNUPG GPG_ LD_ DYLD_ LC_ XDG_`; names `PATH HOME SHELL ENV IFS CDPATH PS4 PROMPT_COMMAND TMPDIR USER LOGNAME LANG TERM DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS PINENTRY_USER_DATA SHELLOPTS UID EUID PPID GROUPS RANDOM SRANDOM SECONDS LINENO HISTCMD EPOCHSECONDS EPOCHREALTIME FUNCNAME DIRSTACK PIPESTATUS OPTIND OPTARG`. `LENDK_` is denied in any case, since lendk's own variables carry it.
- Each CMD and group appears once; a group may be used before its definition.
- Expansion follows word order, inlines groups, and drops duplicates, keeping the first.
- Guarded CMD, which `add` maps only with `--force`: shells `sh dash zsh ksh mksh fish csh tcsh busybox`; interpreters `python* pypy* node nodejs deno bun perl* ruby* php* lua* java`; launchers `env sudo doas su xargs nohup setsid timeout nice make tmux screen`; package tools `npm npx pnpm yarn pip pip3 pipx uv uvx`; agent CLIs `aider claude codex gemini goose opencode`.

### 4.3 PATH setup

A shim works when PATH lists the shim directory before any other copy of the command. `bash -c` reads no rc file, `zsh -c` only `~/.zshenv`, and desktop apps and systemd user services inherit the login environment, so login-level PATH comes first. `lendk init` prints a block of shell code holding the absolute shim directory, so the file that receives it needs no `lendk` on PATH at startup:

```
lendk init sh >> ~/.profile     # bash logins and desktop sessions (~/.bash_profile when it exists)
lendk init sh >> ~/.zshenv      # every zsh, zsh -c included
lendk init bash >> ~/.bashrc    # optional prompt hook; zsh: lendk init zsh >> ~/.zshrc
lendk init systemd > ~/.config/environment.d/99-lendk.conf
```

- `init sh` moves the shim directory to the front of PATH; in `~/.zshenv` that covers every `zsh -c`, even under a harness that prepended its own directory.
- `init bash|zsh` repeats that before every prompt, against version managers and virtualenvs.
- The environment.d file sorts after `99-environment.conf`, which Ubuntu links to `/etc/environment` and which sets PATH.
- macOS: also `~/.zprofile`, since `path_helper` reorders PATH after `~/.zshenv`. Dock-launched apps read none of these files.
- Blocks sit between `# >>> lendk >>>` and `# <<< lendk <<<`. Rerun `init` after changing `LENDK_SHIMS`.

Real binaries still resolve in PATH order, so a virtualenv's `llm` is the one that runs.

### 4.4 Quick start

Four commands, bash on Linux:

```
curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash
exec bash -l
pass insert env/GH_TOKEN
lendk add gh GH_TOKEN
```

Command 1 installs lendk and adds a PATH block to the login file; command 2 starts a login shell that reads it. Desktop apps see the shims after the next desktop login.

## 5. Agent contract

### 5.1 Interactivity

A call is interactive when `LENDK_PROMPT=allow`, or when `LENDK_PROMPT` is unset or `auto` and stdin or stderr is a terminal. `never` is never interactive; other values are `usage`.

Testing stderr keeps git credential helpers interactive (stdin a pipe, stderr the terminal). Probing `/dev/tty` is rejected: agents launched from a terminal still have one, and a curses pinentry would seize it. An agent in a pseudo-terminal counts as interactive, so `LENDK_TIMEOUT` bounds its wait; `LENDK_PROMPT=never` makes it fail fast. Without a terminal, `lendk unlock` is a probe.

### 5.2 Fail fast, never wait forever

Every backend read appends `--status-fd` to `PASSWORD_STORE_GPG_OPTS`, after the user's value; non-interactive calls also append `--pinentry-mode error`. Measured with GnuPG 2.4.4, pass 1.7.4 and a recording `pinentry-program`:
- `--pinentry-mode error`, cold cache: exit 2 in about 30 ms, status `ERROR pkdecrypt_failed 67108949` (code 85), no pinentry, in both pass branches; warm, it decrypts. `--batch` alone launches pinentry; `--pinentry-mode cancel` gives code 99, a user's Cancel.
- With stdin piped, pass sends pinentry `ttyname=not a tty`; curses pinentry fails (FR15).
- Killing gpg makes gpg-agent interrupt a waiting pinentry, which stays a zombie until the agent reaps it.
- With `pinentry-mode loopback`, gpg prompts on the terminal itself, so it must run in the terminal's foreground process group (FR17); pass's `--batch` branch refuses such prompts. After the handoff lendk sends SIGCONT to its own process group to resume a pipeline neighbor the prompt stopped, which also resumes a sibling the caller stopped on purpose. Every other pinentry runs under gpg-agent and needs no terminal from lendk.

Classification reads the low 16 bits of the first `ERROR` status value, never translated text. Non-interactive, codes 85 and 99 are `locked`. An interactive call that started with SIGTTOU ignored (a command substitution, some harnesses) cannot take the terminal; when gpg is set to `pinentry-mode loopback` in `gpg.conf` or `PASSWORD_STORE_GPG_OPTS`, it also gets `--pinentry-mode error`, so no prompt shows whose typed passphrase would reach the caller's shell, and 85 and 99 are `locked`; other pinentries prompt as usual. Otherwise interactive, 85 is `decrypt`, and 99 or Ctrl-C at a loopback prompt is `canceled`; an expired `LENDK_TIMEOUT` is `timeout`; any other failure is `decrypt`.

### 5.3 Stderr contract and exit codes

Before exec, every stderr line is `lendk: CLASS: TEXT. FIX` or `lendk: notice: TEXT.`; a notice reports a change or a risk, never a failure. Backend stderr never passes through raw; `env` stands for the prefix. A nested shim's line reaches the caller through the outer command's stderr.

The CLASS is the contract. Exit codes are hints, not unique: after exec the target's codes pass through, CPython exits 120 when flushing stdout fails, and docker, coreutils `env` and `timeout`, and `git bisect run` give 125 to 127 their own meanings. 0 is success; 1 means `check` found a problem.

CLASS (hint): TEXT. Interactive FIX.
- `usage` (2): what is wrong. `See: lendk --help`
- `guarded` (2): `CMD runs other programs, so its keys reach all of them.` `To map it anyway: lendk add --force CMD WORD...`
- `unsupported` (125): `bash V found; lendk needs bash 4.4 or later.` `Put a newer bash first on PATH.` Or: `GnuPG V found; lendk needs GnuPG 2.4 or later.` `Upgrade GnuPG.`
- `locked` (120, non-interactive, or a loopback prompt that cannot take the terminal): `env/KEY needs the gpg passphrase and this call cannot prompt.`
- `canceled` (120, interactive only): `passphrase entry for env/KEY was canceled.` `Run the command again to retry.`
- `timeout` (120): `env/KEY: gpg did not finish within N s.` `Retry; a hardware token may need a touch, or raise LENDK_TIMEOUT.`
- `map` (125): `MAP:LINE: TEXT.` `Fix the line, then run: lendk check`; or, when `add` names a group the map does not define, `MAP: group @NAME is not defined.` `Define it first: lendk add @GROUP KEY...`
- `unmapped` (125): `CMD is not mapped.` `Map it: lendk add CMD KEY..., or name keys: lendk run KEY... -- CMD`
- `missing-key` (125): `env/KEY is not in the store.` per missing key, `Add it: pass insert env/KEY`; or `env/KEY has an empty first line.` `Set it: pass edit env/KEY`; for `unlock` without names, `MAP does not exist.` `Create it with lendk add, or name the keys to unlock.`, or `no key mapped in MAP is in the store.` `Add a mapped key with pass insert, then retry.`
- `decrypt` (125): `env/KEY: gpg says: TEXT.`, TEXT being gpg's last stderr line. `See gpg's error: lendk unlock KEY`
- `unsafe` (125): `PATH is writable by others.` or `PATH is owned by another user.` `Fix it: chmod go-w PATH, or recreate it as your own`
- `write` (125): `PATH: TEXT.` `Fix it, then run: lendk sync`
- `exec` (126): `PATH is not executable.` `Fix it, or unmap it: lendk rm CMD`
- `not-found` (127): `CMD is not on PATH outside SHIMS.` `Install it, or unmap it: lendk rm CMD`
- `lendk-missing` (127): printed by shims (FR29) for every caller.

Non-interactive FIX: `usage` and `lendk-missing` unchanged; `locked`, `timeout`, `decrypt`: `Ask the user to run 'lendk unlock KEY' in a terminal, then retry.`; `not-found`: `Install CMD, or ask the user.`; the rest: `Stop and ask the user.` So no non-interactive message suggests `lendk add`, `lendk rm`, `lendk run` with keys, `pass`, or printing the environment; no message suggests installing lendk from a package registry.

## 6. Functional requirements

Each FR has a bats test whose name starts with its ID; `pass` is a call-logging mock unless stated. Tests assert on the `lendk: CLASS:` line, never on an exit code alone, and judge processes by state: a zombie counts as gone.

Injection (`run` and shims):
- FR1 The target's environment equals the caller's plus the injected keys and `LENDK_INJECTED` (`env -0` diff), except `_`, `PWD` and `SHLVL`, which bash maintains, and an exported `BASHOPTS`, which gains `execfail` so a failed exec returns to lendk.
- FR2 A key with a non-empty value in the caller's environment is not decrypted and keeps its value.
- FR3 Order: parse; check paths (FR28); read the map lines FR23 needs; resolve CMD; confirm every key exists; check GnuPG (FR22); decrypt all; export; exec. Any failure exits before CMD starts; `missing-key` lists every missing key.
- FR4 Values stay in unexported variables until every decrypt succeeds, then are exported just before exec. A mock backend recording its environment sees no injected name on the second of two keys; `strace -f --seccomp-bpf -v -s 4096 -e trace=execve` shows the sentinel only in the target's execve.
- FR5 CMD containing `/` is used as given; otherwise the first executable regular file named CMD on PATH, skipping entries that canonicalize to the shim directory and files canonically inside it.
- FR6 lendk `exec`s the target: argv0 as given, arguments unchanged, the target's own status and signals (status 7 propagates; SIGTERM reaches it). A failed exec gives `exec`. lendk checks the file first, so bash's own message appears only when the kernel refuses a file that passed those checks (format error, text file busy): bash's lines come first, and the `exec` line ends stderr.
- FR7 The target gets the caller's PATH, umask and open file descriptors; files lendk creates are private under any umask (umask 000 and 022, an extra caller descriptor).
- FR8 Backend processes (pass, gpg, and any gpg-agent gpg starts) get an environment built from scratch: shim-free PATH, `PASSWORD_STORE_GPG_OPTS` as 5.2 sets it, `GPG_TTY` (FR15), and the caller's `HOME USER LOGNAME LANG LC_* TERM TMPDIR DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR GNUPGHOME PINENTRY_USER_DATA` and other `PASSWORD_STORE_*` when set. Keys, exported functions, `BASH_ENV` and `ENV` never reach them (a mock `pass` records its environment, called directly and through a nested shim whose caller holds other keys).
- FR9 lendk discards every shell function it inherits before running any command, so exported functions named `pass`, `env`, `mktemp` or `printf` change nothing.
- FR10 A value is the entry's first line without its newline; an empty first line is `missing-key`.
- FR11 Named keys replace the map entry. Without keys, `run -- CMD` uses the entry for CMD's basename; no entry is `unmapped`.
- FR12 `LENDK_INJECTED` holds the caller's `LENDK_INJECTED` names, then the names this call exported, space-separated, deduplicated; never a value.
- FR13 `run` without `--` is `usage`; if a word names an executable on PATH, the text says `'gh' is a command; put -- before it`.

Agent contract:
- FR14 Interactivity, backend options and classification follow 5.1 and 5.2, the user's `PASSWORD_STORE_GPG_OPTS` otherwise preserved (matrix over terminal stdin and stderr via `script`, and each `LENDK_PROMPT` value).
- FR15 In interactive calls, when `GPG_TTY` is unset or not a character device, the backend, never the target, gets `GPG_TTY` naming stdin's terminal, else stderr's.
- FR16 `LENDK_TIMEOUT` bounds all backend work of a call, every key included: default 60 s interactive, 10 s otherwise; a set value (1 to 3600, else `usage`) applies to both. On expiry lendk stops the backend without `timeout(1)` and exits with `timeout` no sooner than `LENDK_TIMEOUT` s and no later than `LENDK_TIMEOUT` + 2 s after it started, cleanup included, even when a backend child ignores TERM.
- FR17 No process of a call outlives it: after expiry, TERM, INT or HUP to lendk, or TERM or KILL to its process group, the backend, its children, lendk's watchdog and the call's pinentry are gone within 2 s; after exec, within 1 s. When gpg prompts on the terminal itself (`pinentry-mode loopback`) and lendk's process group owns the terminal, lendk hands the terminal to the backend for the prompt and takes it back before exec; Ctrl-C there gives `canceled`. Otherwise the backend never takes the terminal, so a pipeline neighbor such as `less` keeps working, and a lendk call in a background job gives `timeout` instead of stopping.
- FR18 Real `pass` and GnuPG, temporary `GNUPGHOME`, passphrase-protected key, recording `pinentry-program`, with and without a `gpg2` on PATH (pass's `--batch` branch): (a) cold non-interactive: `locked` within 2 s, recorder not launched; (b) primed via loopback: exit 0; (c) `LENDK_PROMPT=allow`: recorder launched; (d) interactive, stdin piped, stderr a terminal: recorder gets stderr's terminal as `ttyname`; (e) recorder answers Cancel: `canceled`; (f) recorder never answers, `LENDK_TIMEOUT=2`: `timeout` within 4 s, recorder gone; (g) KILL to lendk's process group while the recorder waits: recorder gone within 2 s; (h) without `gpg2`, `pinentry-mode loopback` in `gpg.conf`, passphrase typed into a pseudo-terminal: the target gets the value; (i) as (h), called in a command substitution of an interactive shell: `locked`, no prompt shown.
- FR19 Every stderr line before exec matches a 5.3 pattern, except bash's lines on a kernel refusal (FR6); no non-interactive line in the suite makes a suggestion 5.3 forbids.
- FR20 No verb writes a value to stdout, stderr, a file, any argv, or any environment but the target's: a sentinel value appears in no test output, file under the test HOME or TMPDIR, or argv. lendk runs `set +x +v` before reading values, so `bash -x` and an exported `SHELLOPTS=xtrace` expose nothing.
- FR21 lendk never reads stdin and never prompts; the backend's stdin is `/dev/null`; in interactive calls only pinentry or gpg's loopback prompt faces the user.
- FR22 lendk needs bash 4.4 and GnuPG 2.4. Its opening lines parse in bash 3.2 and give `unsupported` under an older bash (bash 3.2 and 4.3 images). Before the first decrypt, `run` and `unlock` give `unsupported` when the gpg pass uses (`gpg2` when on PATH, else `gpg`) reports a version below 2.4 (stub reporting 2.2.27).

Map and shim directory:
- FR23 `run` and `unlock` read only the lines for their CMD and its groups, and give `map` only when those are invalid; a bad line, another command's duplicate or a merge-conflict marker elsewhere leaves them working. `add` and `rm` need the whole map valid. `sync` writes shims for every line whose first field is a valid CMD, then reports each violation (exit 125).
- FR24 `add NAME WORD...` creates the entry or appends absent words in order. `rm NAME` removes the entry and its shim; `rm NAME WORD...` removes those words, and the entry when none remain. A guarded CMD without `--force` is `guarded`; with it, a `notice` names the risk. Both verbs then sync and print the affected rows in `check` format (FR32).
- FR25 `add` and `rm` validate first and change nothing on error: invalid, reserved or denied names, and groups inside groups, are `usage`; an unknown group, or removing a referenced group, is `map`. Removing an absent name or word exits 0 with a `notice`.
- FR26 `add`, `rm` and `sync` hold a lock: an atomic `mkdir` of `SHIMS.lock` recording the owner's PID. A waiter retries for 10 s, then gives `write` naming the lock; it breaks a dead owner's lock only while holding `SHIMS.lock.break`, also an atomic `mkdir`, after rereading the owner, so no two waiters both break and hold it. Twenty concurrent `add` calls, started with a dead owner's lock present, leave twenty entries. Runtime calls never lock.
- FR27 Map writes change only the affected line or append one, rename a temporary file from beside the target over it, follow a symlinked map, and leave the map mode 0600 under any umask, creating its directory 0700 when absent.
- FR28 The map, its directory (after following a symlink) and the shim directory must be owned by the user and not writable by group or others. `run` and `unlock` give `unsafe` when the map or its directory fails; `add`, `rm` and `sync` also when the shim directory fails. `init` checks only the shim directory, when it exists, and then prints no code. `sync` creates the shim directory 0700 under any umask.

Shims:
- FR29 `sync` writes one shim per mapped command, mode 0755, holding the absolute path lendk was invoked by, symlinks unresolved, so versioned upgrades behind a stable symlink keep working:
  ```
  #!/bin/sh
  # lendk shim v1: generated by lendk sync, edits are overwritten
  lendk='/home/alice/.local/bin/lendk'
  [ -x "$lendk" ] || { echo "lendk: lendk-missing: $lendk is missing, so gh did not run. The user must reinstall lendk from its project repository, then run: lendk sync" >&2; exit 127; }
  exec "$lendk" run -- 'gh' "$@"
  ```
- FR30 `sync` deletes only files whose second line starts with `# lendk shim `, removing those of unmapped commands. A foreign file named like a mapped command stays untouched and gives `write` after the other shims are written. A second `sync` changes no byte.

`check`:
- FR31 `check` never calls the backend read (zero mock calls); it tests entries by file existence, so an empty value (FR10) shows as `ok`.
- FR32 Stdout: `# map`, `# shims`, `# store` lines; `# problem: TEXT (FIX)` lines; then groups and commands, sorted, as `NAME<TAB>KEYS<TAB>STATUS`, STATUS being `ok` or `; `-joined problems with a FIX in parentheses; non-interactive FIXes are `ask the user`, except `lendk sync` and `lendk run -- CMD`. `check NAME...` keeps rows named NAME, holding key NAME, or using group NAME.
- FR33 Detects: map violations; missing key; command not found; no shim; stale shim (differs from FR29 output); stray shim; foreign files in the shim directory; a shim whose lendk path is not executable; `unsafe` paths; shim directory not on PATH; shadowed, naming the earlier path; a GnuPG below 2.4; a mapped key set in the environment and absent from `LENDK_INJECTED`, so no such problem under a `run` target or nested shim. Exit 1 when anything shown has a problem. No map, or a map without entries, as on a fresh install, is no problem: `check` prints the notice `lendk: notice: no command is mapped yet, so lendk gives no keys; map one with lendk add CMD KEY.`, or without a terminal `...; ask the user which commands to map.`

`unlock`, `init`, help, docs:
- FR34 `unlock` decrypts each named key (default: the first mapped key present), discards values, prints `unlocked`, and follows `run`'s interactivity, timeout and class rules; no mapped key present is `missing-key`. Stores with per-folder `.gpg-id` recipients need `unlock KEY` per recipient.
- FR35 `init` reads no map and prints 4.3's block, holding the absolute shim directory: `sh` moves it to the front of PATH without duplicates; `bash` and `zsh` add a prompt hook repeating that plus `hash -r` or `rehash`, registered once even when the block runs twice; `systemd` prints `PATH=` with the absolute shim path, then `${PATH}`, as systemd's environment.d generator accepts.
- FR36 `--help` prints verbs, map grammar, name lists, classes with exit hints and environment variables, exit 0; `--version` prints `lendk X.Y.Z`; no arguments or an unknown verb is `usage`.
- FR37 The README covers: key features before the quick start; the 4.4 quick start; installation for humans (`install.sh`, its options and changes, `make install`, uninstall) and a fenced prompt for AI agents that runs the installer with `--yes`, asks before `--install-deps`, sudo, a GPG key or `pass init`, installs the skill with `--skill-dir`, verifies `--version`, the login PATH, `check` and, with consent, a throwaway `run`, never runs `pass show` or prints secrets, and ends with a report; the agent prompt names only options `install.sh --help` lists, classes it emits and verbs `--help` lists; installing only from the project repository; 4.3 for bash, zsh, systemd and macOS; the security model and `s2k-count` trade-off; cache TTLs and flushing; `lendk run -- CMD` by absolute path in cron, systemd and MCP configs; the git credential helper `!lendk run -- gh auth git-credential`, replacing the absolute path `gh auth setup-git` writes; PATH-bypassing launchers; the classes and name lists as `--help` prints them; an agent block: act on the `lendk: CLASS:` line; on `locked`, `timeout` or `canceled`, stop and ask the user; never run `pass`, `lendk add`, `lendk rm` or `lendk run` with keys, or print the environment.
- FR38 `skills/lendk/SKILL.md` is an Agent Skill (frontmatter `name: lendk` and a `description` of when to load it) that teaches the mental model, every verb, the class table with what to do for each class, the agent rules of FR37, answers to common questions and troubleshooting with `check`. Its verbs and classes are exactly `--help`'s; `install.sh --skill-dir DIR` copies it to `DIR/lendk`.

`install.sh`:
- FR39 `install.sh` is POSIX sh: it runs under dash, busybox sh and macOS's bash 3.2, as a file or piped (`curl ... | bash`, `| sh`, `| bash -s -- OPTION...`). All work sits in functions and `main "$@"` is the last line, so a truncated download runs nothing. No command it runs reads its stdin.
- FR40 It downloads `lendk.tar.gz` and `SHA256SUMS` from `BASE/latest/download/`, or `BASE/download/vX.Y.Z/` with `--version X.Y.Z`. BASE is `https://github.com/v-bonilla/lendk/releases`, or `LENDK_INSTALL_BASE_URL` for tests and mirrors, which must start with `https://` or `file:///`; downloads are https-only and `file://` is copied. A SHA-256 mismatch is `checksum` and installs nothing. The archive's `lendk-X.Y.Z/bin/lendk` is renamed into `PREFIX/bin` (`--prefix`, default `~/.local`), without root.
- FR41 It always detects bash 4.4+, GnuPG 2.4+, pass, curl or wget, tar and `sha256sum` or `shasum`. When any is missing it prints the exact command for apt-get, dnf, pacman, zypper, apk or brew, with `sudo` when not root, the index refresh the manager needs (none for pacman, whose `-Sy` alone is an unsupported partial upgrade; its failure line says to run `pacman -Syu` first) and no recommended packages, and stops with `missing-deps`. `--install-deps` runs that command, with `sudo -n` without a terminal; when it fails, the line names the command to run by hand and `sudo -v`. An uninitialized pass store prints the `gpg --quick-generate-key` and `pass init` steps for a human to run in their own terminal; the installer never runs them.
- FR42 Unless `--no-modify-path`, it writes one `# >>> lendk-install >>>` block, holding a bash 4.4+ directory when the first bash on PATH is older, `PREFIX/bin` and `lendk init sh`'s output, with every path quoted for sh, to `~/.bash_profile` or else `~/.profile`, plus `~/.zshenv` for zsh users and `~/.zprofile` for zsh on macOS. It starts the block on a new line, replaces an existing block, and leaves a file whose block is current unchanged. On Linux with a systemd user session it writes `lendk init systemd` to `environment.d/99-lendk.conf`. It prints each change.
- FR43 Except with `--help`, the last line is `lendk-install: ok: TEXT` (exit 0) or `lendk-install: CLASS: TEXT`, CLASS one of `usage` (exit 2), `unsupported-os`, `missing-deps`, `download`, `checksum`, `install` or `path` (exit 1), also on a bad HOME and on HUP, INT or TERM, after which its temporary directory is gone. It never prompts with `--yes` or without a terminal on stdin.
- FR44 `--uninstall` removes the installer's blocks, an environment.d file starting with `# >>> lendk >>>`, marker-bearing shims, the skill copy under `--skill-dir`, and `PREFIX/bin/lendk` only when its second line is `bin/lendk`'s; never the map or the store. Its marker strings equal `bin/lendk`'s. `--skill-dir DIR` copies the release's `skills/lendk` to `DIR/lendk`.

## 7. Non-functional requirements

- NFR1 Shim overhead: with keys preset and a 50-entry map, shim exec to target exec exceeds a direct exec of the target by at most 20 ms median and 40 ms p95 over 200 runs (`make bench`).
- NFR2 Decrypt cost: `run` makes one backend read per key the caller did not set, `unlock` one per key it names, in sequence; other verbs make none. With real GnuPG, a warm cache and a key protected at `s2k-count 8388608`, a 3-key call takes at most 500 ms median (`make bench`).
- NFR3 Bash 4.4+ and GnuPG 2.4+ (FR22). Tier 1 is Linux (Debian 13, Ubuntu 24.04+, current Fedora): every change passes `make check` and `make check-docker` (AC1). macOS is supported with bash and GnuPG from Homebrew, Homebrew's bash first on the login PATH: `make test` passes on GitHub's macOS runner, where the strace, systemd and ETXTBSY checks skip because macOS lacks them, for every release tag and manual run while the repository is private and for every change once it is public. One limitation is macOS-only: after a loopback passphrase prompt inside a pipeline whose neighbor reads the terminal, the outer interactive bash can still show that neighbor as stopped; `fg` resumes it. `bin/lendk` uses POSIX utilities and options, plus `mktemp -d TEMPLATE`, plain `readlink` and fractional `sleep`, which GNU, BSD and busybox share; never `timeout`, `flock`, `stat`, `readlink -f` or `setsid`. It reads `/proc/PID/stat`, or runs `ps` where `/proc` is absent, only to learn whether its process group owns the terminal before a loopback prompt.
- NFR4 Runtime dependencies: bash 4.4+, pass 1.7+, GnuPG 2.4+, POSIX utilities. Development: bats-core as a pinned git submodule, shellcheck pinned through `uvx` with zero findings, Docker for `make check-docker`; nothing else.
- NFR5 lendk writes only the map (`add`, `rm`), the shim directory (`add`, `rm`, `sync`) and the lock: no caches or logs. Temporary files are mode 0600 in a 0700 directory, hold no value, and are gone before exit or exec, and within 2 s when lendk is killed.
- NFR6 No network, telemetry or auto-update: every verb run under `strace -f --seccomp-bpf -e trace=connect` makes no AF_INET or AF_INET6 `connect`; the source has no `curl`, `wget`, `nc` or `/dev/tcp`. `check` is the self-report for drift, and a GnuPG status-code change fails FR18.
- NFR7 One executable bash file. The backend is `backend_has KEY` and `backend_read KEY`; nothing else touches pass or the store.
- NFR8 Verbs, `--force`, classes, exit-code hints, map grammar, name lists, environment variables and the shim text are stable within 1.x; 1.x only adds entries. `bin/lendk` holds the only copy of the name lists and the class table, and `--help` prints them. `test/contract.bats` checks that `--help` holds every entry this document lists, that the README's lists match `--help`, and that `sync` writes FR29's text.
- NFR9 Repo: MIT license held by `v-bonilla`; no em-dashes, real keys, email addresses, or home paths other than `/home/alice`.

## 8. Files and configuration

- Map: `${XDG_CONFIG_HOME:-~/.config}/lendk/map`, or `LENDK_MAP`.
- Shims: `${XDG_DATA_HOME:-~/.local/share}/lendk/shims`, or `LENDK_SHIMS`, set wherever lendk runs. Lock: `SHIMS.lock`.
- Store: `~/.password-store`, or `PASSWORD_STORE_DIR`. Entry prefix: `env`, or `LENDK_PREFIX`.
- `LENDK_PROMPT`: `auto` (default), `never`, `allow`. `LENDK_TIMEOUT`: seconds (FR16).

Relative XDG values are ignored. lendk sets `LENDK_INJECTED` for targets and `GPG_TTY` for the backend only. Cron, systemd units and MCP configs skip rc files and need any overrides set too.

## 9. Install, upgrade, uninstall

- Install only from the project repository: `install.sh` (FR39 to FR44), or `make install` from a checkout. `make install` copies `bin/lendk` to a temporary file in `$PREFIX/bin`, makes it executable and renames it over `lendk`, so a running copy keeps reading the old file. `PREFIX` defaults to `$HOME/.local` and must be absolute; `DESTDIR` is honored.
- Upgrade: `git pull`, then `make install`. With versioned install directories behind a stable symlink, run `lendk sync` once through the symlink.
- Uninstall: delete the `# >>> lendk >>>` blocks and the environment.d file, then `make uninstall`: it removes marker-bearing shims, the shim directory and lendk's default data directory if empty, and the installed file only when its second line is `bin/lendk`'s, never the map, store or rc files.

## 10. Alternatives considered

gopass `env` (a whole subtree), fnox and secretspec (manifests), CyberArk summon, Infisical `run` and OpenBao agent exec (servers), sops `exec-env` (encrypted file) and direnv (a whole directory) each need a prefix command or scope keys wider than one command. Only lendk makes per-command least privilege the default with no prefix: PATH shims cover every caller, and pass stays the only store.

## 11. Acceptance criteria for v1

- AC1 `make check` (shellcheck with zero findings, NFR9 repo lint, the suite on the host) and `make check-docker` (the suite in Ubuntu 24.04 with real GnuPG, and in bash 4.4 on busybox without GNU coreutils) pass; every FR and NFR ID names a test or bench case.
- AC2 FR18 passes on GnuPG 2.4 in both pass branches; FR4 and FR20 pass under strace; FR22 passes under bash 3.2 and 4.3.
- AC3 `make bench` meets NFR1 and NFR2 on the development host; CI reports it without gating.
- AC4 Fresh HOME whose `.profile` and `.bashrc` mirror Debian's `/etc/skel` (`.bashrc` sourced before `~/.local/bin` joins PATH, and returning early when non-interactive), stub `gh` recording `GH_TOKEN`, `make install`, the 4.3 blocks, `add gh GH_TOKEN`: the key reaches `gh` from interactive bash under `script`; `bash -lc`; `zsh -c` under a parent that prepended a directory holding another `gh`; Python `subprocess` without a shell, started from `sh -lc` like a desktop session; a nested shim, with one decrypt. `/usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator` puts the shim directory first; the parent shell lacks `GH_TOKEN`; `make uninstall` leaves only the map.
- AC5 G3: on the AC4 HOME with a scratch GnuPG key and store, the README's four quick-start commands run as written, except that command 1 runs the working tree's `install.sh` against a `make dist` release served from `file://` and command 3 reads the value from stdin; commands 3 and 4 run in `bash -l` shells, which command 2 starts. A stub `gh` run by `bash -lc gh` then receives `GH_TOKEN`. The README has every FR37 topic.
- AC6 The GitHub Actions workflow passes on the private repository before it is made public, every job, macOS included.

## 12. Failure signals

Any of these reports means v1 failed, and the next release fixes it first:
- An agent waiting in a lendk call past `LENDK_TIMEOUT` + 2 s, or a backend, watchdog or pinentry outliving its call.
- A mapped command running without its keys after an upgrade or PATH change while `check` says `ok`.
- A false `check` problem.
- A secret value in lendk output, argv, a file, or a helper's environment.
- An agent widening the map or printing a key after following a lendk message.
