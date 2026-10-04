# lendk

lendk gives each API key only to the commands you choose, and only while they run. You type `gh`, `gh` gets `GH_TOKEN`, and nothing else does.

The common habit is a line like `export OPENAI_API_KEY=...` in a shell startup file. That hands every key to every program you start: AI coding agents, package install scripts, any tool you try once. With lendk, your keys stay encrypted in [pass](https://www.passwordstore.org/), a password manager that keeps each secret in a GPG-encrypted file. You tell lendk once which command gets which key. After that you run the command as you always do, and lendk decrypts its key for that run.

## Contents

- [Key features](#key-features)
- [Quick start for humans](#quick-start-for-humans)
- [Examples](#examples)
  - [gh with a GitHub token](#gh-with-a-github-token)
  - [A group of keys for Claude Code or Codex](#a-group-of-keys-for-claude-code-or-codex)
- [Installation](#installation)
  - [For humans](#for-humans)
  - [For AI agents](#for-ai-agents)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [Daily use](#daily-use)
  - [Map file](#map-file)
- [How it works](#how-it-works)
  - [Security model](#security-model)
  - [Decrypt speed and `s2k-count`](#decrypt-speed-and-s2k-count)
- [PATH setup](#path-setup)
- [Callers that skip PATH](#callers-that-skip-path)
  - [Git credential helper](#git-credential-helper)
  - [cron, systemd units, MCP servers](#cron-systemd-units-mcp-servers)
  - [Other PATH-bypassing launchers](#other-path-bypassing-launchers)
- [Troubleshooting](#troubleshooting)
- [Agent contract](#agent-contract)
- [Requirements](#requirements)
- [License](#license)

## Key features

- **One key, one command.** `gh` gets `GH_TOKEN`. Your shell and the other programs you start from it get no key.
- **Nothing new to type.** You keep running `gh`. lendk puts a small script named `gh`, called a shim, in a directory your system searches first. The shim gets the key, then starts the real `gh`. Scripts and AI agents that run `gh` get the same result.
- **Keys stay encrypted.** They live in pass, not in your shell startup files. lendk never writes a key to a file, a log, a command line or its own output.
- **Works with AI agents.** A call without a terminal never waits at a passphrase prompt nobody can answer. Every failure is one line that names the problem and the fix.
- **`lendk check` shows what is wrong.** It lists which command gets which key, and reports missing keys and setup mistakes, without decrypting anything.
- **Small and quiet.** One bash file. No background service, no saved copy of a decrypted key, no telemetry, no update check. It uses the network only when you run `lendk upgrade`.
- **Linux and macOS, no root needed.** The install script checks the download against its checksum before it installs anything.

## Quick start for humans

You need a GPG key and a pass store initialized for it; the installer prints the steps when the store is missing.

<!-- quickstart -->
```
curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash
exec bash -l   # PATH setup
pass insert env/GH_TOKEN
lendk add gh GH_TOKEN
```
<!-- quickstart -->

Now `gh` gets `GH_TOKEN`, and `echo "$GH_TOKEN"` in your shell prints nothing.

To have an AI agent install lendk, give it the prompt under [For AI agents](#for-ai-agents).

## Examples

### gh with a GitHub token

Store the token, map it to `gh`, then run `gh` as you always do:

```
pass insert env/GH_TOKEN       # pass asks for the token and encrypts it
lendk add gh GH_TOKEN          # gh gets GH_TOKEN from here on
gh repo list                   # works: gh received the token
echo "${GH_TOKEN:-not set}"    # prints "not set": the shell itself has no GH_TOKEN
```

### A group of keys for Claude Code or Codex

Claude Code and Codex both need two web search keys here. Store the keys, name them as a group, then give the group to each agent:

```
pass insert env/EXA_API_KEY
pass insert env/BRAVE_API_KEY
lendk add @search EXA_API_KEY BRAVE_API_KEY    # a group of keys named search
lendk add --force claude @search               # Claude Code gets both keys
lendk add --force codex @search                # Codex gets the same group
```

These commands add three lines to the map file, `~/.config/lendk/map`:

```
@search EXA_API_KEY BRAVE_API_KEY
claude @search
codex @search
```

`--force` is needed because an agent CLI starts other programs: shell commands, scripts, MCP servers. The keys reach everything it runs, so `lendk add` refuses until you confirm with `--force`.

A tighter setup leaves the agent unmapped and gives the key only to the MCP server that needs it: in the agent's MCP config, start the server through lendk by its absolute path, as `/home/alice/.local/bin/lendk run EXA_API_KEY -- some-mcp-server`. See [cron, systemd units, MCP servers](#cron-systemd-units-mcp-servers).

## Installation

Install only from this repository.

### For humans

```
curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash -s -- --skill-dir DIR
```

The installer options go after `bash -s --`, for example `curl -fsSL .../install.sh | bash -s -- --yes`:

```
--version X.Y.Z    install release X.Y.Z instead of the latest
--prefix DIR       install into DIR/bin (default ~/.local)
--yes              never prompt (also implied when stdin is not a terminal)
--install-deps     run the package manager command for missing dependencies
--no-modify-path   leave login files and the environment.d file alone
--skill-dir DIR    copy the lendk agent skill to DIR/lendk
--uninstall        remove what this installer added, never the map or the pass store
```

With `--install-deps` and no terminal, sudo runs as `sudo -n` and fails when it needs a password; run `sudo -v` first, or run the printed command yourself.

#### From source

```
git clone https://github.com/v-bonilla/lendk
make -C lendk install                  # PREFIX defaults to ~/.local; DESTDIR is honored
```

`make install` renames a new file over the old one, so a running lendk keeps reading its copy.

### For AI agents

Paste this prompt into your coding agent:

<!-- agent-prompt -->
```
Install lendk (https://github.com/v-bonilla/lendk) on this machine. It gives API keys stored in
pass only to the commands mapped to them.

1. Run the installer without prompts:
   curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash -s -- --yes
   If you support Agent Skills, add --skill-dir with your skills directory, for example
   --skill-dir ~/.claude/skills for Claude Code, so you learn how to use lendk.
2. The last output line is "lendk-install: ok: TEXT" or "lendk-install: CLASS: TEXT". On a CLASS,
   diagnose the cause, fix it and rerun. Ask me before rerunning with --install-deps or running
   anything with sudo. Never bypass a checksum failure. If the output says the pass store is not
   initialized, show me the gpg --quick-generate-key and pass init steps; I run them in my own
   terminal, since gpg asks for a passphrase.
3. Verify, through login shells, since your own shell predates the PATH change:
   - bash -lc 'lendk --version' prints the version.
   - bash -lc 'command -v lendk; printf "%s\n" "$PATH"' finds lendk, and the first PATH entry is
     the shim directory (~/.local/share/lendk/shims). If zsh is installed, check zsh -lc the same way.
   - bash -lc 'lendk check' prints its report without decrypting. On a fresh install it prints the
     "# map", "# shims" and "# store" lines and the notice "no command is mapped yet", and exits 0;
     that is expected. Relay any "# problem" line or other row it shows.
   - Only if I agree: an end-to-end test with a throwaway key, with the path to lendk, since your
     shell predates the PATH change:
       printf 'lendk-test\n' | pass insert -m env/DEMO_TOKEN
       ~/.local/bin/lendk run DEMO_TOKEN -- sh -c 'test -n "$DEMO_TOKEN" && echo received'
       pass rm -f env/DEMO_TOKEN
     Run the cleanup, pass rm -f env/DEMO_TOKEN, even when the run fails. On a "lendk: locked:"
     line, ask me to run ~/.local/bin/lendk unlock DEMO_TOKEN in a terminal, retry once, then clean up.
4. Never read or print a secret, never run pass show, and never print the environment.
5. Finish with a short report: what you installed and which files changed, each check's result,
   and what I still have to do (open a new login shell, store keys with pass insert env/KEY, map
   commands with lendk add CMD KEY).
```
<!-- agent-prompt -->

## Upgrade

```
lendk upgrade
```

It moves lendk to the latest release:

- It downloads the release and checks it against its checksum, as the installer does. It also checks that the file inside is lendk and runs under your bash.
- It replaces one file, the installed `lendk`, by renaming the release's file over it. A lendk that is running at that moment finishes on the old file.
- It prints `upgraded lendk A.B.C to X.Y.Z at PATH`, then runs `lendk sync`, which writes the shims to match the map.
- When the latest release is not higher than your version, it changes nothing and prints `lendk A.B.C is up to date: the latest release is X.Y.Z`. It never downgrades.

It writes that one file and the shims `lendk sync` writes, nothing more. It leaves everything else alone: the map, the pass store, your login files, the environment.d file and a skill copy. It decrypts no key and never prompts. To refresh PATH setup or a skill copy (`--skill-dir DIR`), or to install a release you choose (`--version X.Y.Z`), rerun the installer with the options under [Installation](#installation).

When the upgrade fails, the error is one `lendk: upgrade:` line, and lendk is unchanged:

- A download that fails, a checksum that differs, or a release that holds no lendk your bash can run: retry.
- An install it refuses to touch: a `lendk` that is a symlink, a file that is not lendk's own, a version that is not a release's `X.Y.Z`, or a directory you cannot write. Upgrade lendk the way it was installed. With versioned install directories behind a stable symlink, install the new version beside the old one, move the symlink, and run `lendk sync` once through it.
- A missing tool. `lendk upgrade` needs tar, gzip, `sha256sum` or `shasum`, and curl or wget. It finds them on PATH outside the shim directory, so a `curl` you mapped runs without its shim and gets no key.

`LENDK_TIMEOUT` bounds the download and the checks together: 60 s in a terminal, 10 s otherwise. On a slow connection, raise it: `LENDK_TIMEOUT=300 lendk upgrade`.

`lendk upgrade` trusts this project's GitHub releases over HTTPS, as the installer does. `LENDK_INSTALL_BASE_URL` names another release base, an `https://` or `file:///` URL; any other value is a `usage` error. It moves that trust to whoever serves the URL, so lendk names a set base in a notice. See [Security model](#security-model).

lendk 1.0.0 has no `upgrade`: rerun the installer once, and later versions upgrade themselves.

From a checkout: `git pull`, then `make install`.

## Uninstall

After an install with the installer:

```
curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash -s -- --uninstall
```

- It removes the installer's blocks from your login files, the environment.d file, lendk's shims and the installed `lendk`.
- It never removes the map or the pass store.
- Add `--skill-dir DIR` to remove the skill copy at `DIR/lendk` too.
- Add the `--prefix DIR` you installed with, when you used one.
- Blocks you added yourself with `lendk init` stay. Delete the lines from `# >>> lendk >>>` to `# <<< lendk <<<` in those files.

After an install from source, delete the `# >>> lendk >>>` blocks from your rc files and the environment.d file, then run:

```
make -C lendk uninstall
```

It removes lendk's shims, the shim directory and lendk's data directory if empty, and the installed file when it is lendk's, never the map, the store or your rc files.

## Daily use

```
lendk run [KEY|@GROUP...] -- CMD [ARG...]      # exec CMD with its mapped or the named keys
lendk add [--force] CMD|@GROUP KEY|@GROUP...   # map keys to a CMD (or define a group of keys), then sync
lendk rm CMD|@GROUP [KEY|@GROUP...]            # unmap, then sync
lendk check [NAME...]                          # diagnose without decrypting
lendk sync                                     # write shims to match the map
lendk unlock [KEY|@GROUP...]                   # unlock in a terminal so gpg cache is warm; probe elsewhere
lendk init sh|bash|zsh|systemd                 # print PATH setup
lendk upgrade                                  # replace lendk with the latest release, then sync
lendk --help | --version
```

- Keys live in pass under `env/`: the first line of `env/GH_TOKEN` is the value of `GH_TOKEN`. Rotate a key with `pass edit env/GH_TOKEN`; the next call uses it.
- `lendk add` maps a command and writes its shim. After editing the map by hand, run `lendk sync`.
- `lendk run OPENAI_API_KEY -- ./script.sh` runs one command with the named keys, mapped or not.
- A key already set in the caller's environment wins, so `GH_TOKEN=other gh` works, and a mapped command calling another reuses the key with no second decrypt.
- `lendk unlock` asks for your gpg passphrase once, so later calls without a terminal find the cache warm.
- `gpgconf --reload gpg-agent` forgets cached passphrases, which locks every key again.

### Map file

`~/.config/lendk/map`:

```
@search     EXA_API_KEY BRAVE_API_KEY    # a group of keys
claude      @search                      # Claude Code and Codex get both keys
codex       @search
opencode    BRAVE_API_KEY                # one key, mapped directly
gh          GH_TOKEN
```

- One entry per line; `#` starts a comment. `@NAME KEY...` defines a group of keys; `CMD WORD...` maps a command, WORD being a key or `@NAME`.
- There are no groups of commands: two commands share keys by naming the same group.
- Groups inline in word order; duplicates are dropped, keeping the first.
- lendk refuses keys that steer lendk, pass, gpg, the shell or the loader, and refuses to map its own runtime.
- Guarded commands run other programs, so their keys reach everything they run. `lendk add` maps them only with `--force`, and prints a notice. `claude`, `codex` and `opencode` above are guarded.

The name lists, as `lendk --help` prints them:

```
  reserved commands: lendk bash pass gpg gpg2 gpg-agent gpgconf
  denied key prefixes: BASH LENDK_ PASSWORD_STORE_ GNUPG GPG_ LD_ DYLD_ LC_ XDG_
  denied key names: PATH HOME SHELL ENV IFS CDPATH PS4 PROMPT_COMMAND TMPDIR USER LOGNAME LANG TERM DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS PINENTRY_USER_DATA SHELLOPTS UID EUID PPID GROUPS RANDOM SRANDOM SECONDS LINENO HISTCMD EPOCHSECONDS EPOCHREALTIME FUNCNAME DIRSTACK PIPESTATUS OPTIND OPTARG
  guarded shells: sh dash zsh ksh mksh fish csh tcsh busybox
  guarded interpreters: python* pypy* node nodejs deno bun perl* ruby* php* lua* java
  guarded launchers: env sudo doas su xargs nohup setsid timeout nice make tmux screen
  guarded package tools: npm npx pnpm yarn pip pip3 pipx uv uvx
  guarded agent CLIs: aider claude codex gemini goose opencode
```

## How it works

- `lendk sync` writes one shim per mapped command into `~/.local/share/lendk/shims`, which `lendk init` puts first on PATH. Each shim is a short `sh` script that runs `lendk run -- CMD`.
- `lendk run` reads the map lines for CMD, finds the real CMD on PATH after the shim directory, confirms every key exists, decrypts them all, exports them and `exec`s CMD with its own argv0 and exit status. Any failure stops before CMD starts.
- Values never appear in argv, files, logs or lendk's output. pass and gpg run with an environment built from an allowlist (PATH without shims, HOME, locale, terminal and display variables, GNUPGHOME, `PASSWORD_STORE_*`), so no key or exported shell function reaches them.
- Without a terminal, lendk adds `--pinentry-mode error`, so a locked store fails in milliseconds with a `locked` line instead of a prompt nobody sees. `LENDK_TIMEOUT` bounds all backend work of a call (default 60 s in a terminal, 10 s otherwise), and no process of a call outlives it.
- No daemon, no cache of values, no telemetry, no update check. lendk uses the network only in `lendk upgrade`, and only when you run it. It writes only the map, the shim directory and its lock, and in `lendk upgrade` its own file.

### Security model

lendk protects against ambient exposure: keys reach only mapped commands, `lendk run` targets and their descendants. It also keeps plaintext keys out of rc files and dotfile repos, and keeps agents from hanging on prompts.

It does not protect against:

- Other processes running as you. While gpg-agent holds your passphrase, any of them, an AI agent included, can run `pass show`, read `/proc/PID/environ`, edit the map, the shims or PATH, or replace lendk itself. lendk keeps keys out of an agent's context; it does not stop an agent that goes looking for them.
- A mapped command itself. It holds the key and can print it, as `gh auth token` does, so map only tools you trust with that key.
- Descendants of a mapped command, for their lifetime, and root. Running processes keep old values after a rotation.
- Callers that bypass PATH. They run without lendk's keys and fail, or act under the tool's own stored credentials, such as gh's `hosts.yml` or `~/.aws/credentials`.
- A compromised release. `lendk upgrade` replaces lendk, which reads every mapped key, with the file the latest release holds. It trusts this project's GitHub releases over HTTPS, as the installer does. The checksum comes from the same release, so it catches a corrupt or cut-short download, not a compromised release or account. The download tool reads your own configuration, such as `~/.curlrc`.

### Decrypt speed and `s2k-count`

gpg-agent caches your passphrase, not the unlocked key, so every decrypt re-runs the key derivation. With GnuPG's default work factor that can approach one second per key on slow machines. To cut it to tens of milliseconds, add this to `~/.gnupg/gpg-agent.conf`:

```
s2k-count 8388608
```

Then run `gpgconf --reload gpg-agent` and `gpg --passwd KEYID`, entering the same passphrase: the new count applies only when the key is protected again. The trade-off is real: anyone who copies your secret key file can guess passphrases about 20 times faster, so use this only with a strong passphrase. lendk never changes GnuPG settings.

Cache lifetime is gpg-agent's too. `default-cache-ttl` (seconds) is an idle timer reset by each use; `max-cache-ttl` is an absolute cap. For example, in `gpg-agent.conf`:

```
default-cache-ttl 3600
max-cache-ttl 28800
```

`gpgconf --reload gpg-agent` flushes the cache at any time.

## PATH setup

A shim works when PATH lists the shim directory before any other copy of the command. `bash -c` reads no rc file, `zsh -c` reads only `~/.zshenv`, and desktop apps and systemd user services inherit the login environment, so the login-level PATH comes first. `lendk init` prints a block holding the absolute shim directory between `# >>> lendk >>>` and `# <<< lendk <<<` markers:

```
lendk init sh >> ~/.profile     # bash logins and desktop sessions (~/.bash_profile when it exists)
lendk init sh >> ~/.zshenv      # every zsh, zsh -c included
lendk init bash >> ~/.bashrc    # optional prompt hook; zsh: lendk init zsh >> ~/.zshrc
lendk init systemd > ~/.config/environment.d/99-lendk.conf
```

- `init sh` moves the shim directory to the front of PATH. In `~/.zshenv` that covers every `zsh -c`, even under a harness that prepended its own directory.
- `init bash` and `init zsh` repeat that before every prompt, so version managers and virtualenvs that prepend PATH later do not hide the shims.
- The environment.d file covers systemd user services and desktop sessions started by systemd. It sorts after `99-environment.conf`, which Ubuntu links to `/etc/environment`.
- macOS: also add `lendk init sh >> ~/.zprofile`, since `path_helper` reorders PATH after `~/.zshenv`. Apps launched from the Dock read none of these files.
- Rerun `init` after changing `LENDK_SHIMS`.

Real binaries still resolve in PATH order, so a virtualenv's `llm` is the one the shim runs.

## Callers that skip PATH

### Git credential helper

`gh auth setup-git` writes an empty helper, then an absolute path to gh, into `~/.gitconfig`; the absolute path bypasses the shim. Replace both, whether or not they exist:

```
for host in github.com gist.github.com; do
  git config --global --replace-all credential.https://$host.helper ''
  git config --global --add credential.https://$host.helper '!lendk run -- gh auth git-credential'
done
```

The empty helper keeps any global helper from answering for these hosts.

### cron, systemd units, MCP servers

These start with their own PATH and read no rc file. Call lendk by absolute path and name the command:

```
# crontab
0 * * * * /home/alice/.local/bin/lendk run -- gh repo sync
```

```
# systemd unit
ExecStart=/home/alice/.local/bin/lendk run -- terraform plan
```

```
{ "command": "/home/alice/.local/bin/lendk", "args": ["run", "--", "some-mcp-server"] }
```

Set any overrides (`LENDK_MAP`, `LENDK_SHIMS`, `LENDK_PREFIX`, `PASSWORD_STORE_DIR`) there too. These callers have no terminal, so they get `locked` unless gpg-agent already holds the passphrase; `lendk unlock` in a terminal fills the cache.

### Other PATH-bypassing launchers

Absolute paths, `npx`, `npm run`, `uv run` and similar launchers find the tool without PATH, so the shim never runs. Wrap them: `lendk run OPENAI_API_KEY -- npx some-tool`.

## Troubleshooting

Start with `lendk check`. It never decrypts, and reports map errors, missing keys, missing commands, missing or stale shims, a shim directory absent from PATH, shims shadowed by an earlier PATH entry, and unsafe permissions, each with a fix. It exits 1 when anything shown has a problem.

Every failure is one stderr line, `lendk: CLASS: TEXT. FIX`. The classes, as `lendk --help` prints them:

```
  usage (2): See: lendk --help | See: lendk --help
  guarded (2): To map it anyway: lendk add --force CMD WORD... | Stop and ask the user.
  unsupported (125): Put a newer bash first on PATH. | Stop and ask the user.
  unsupported (125): Upgrade GnuPG. | Stop and ask the user.
  locked (120): Ask the user to run 'lendk unlock KEY' in a terminal, then retry. | Ask the user to run 'lendk unlock KEY' in a terminal, then retry.
  canceled (120): Run the command again to retry. | Stop and ask the user.
  timeout (120): Retry; a hardware token may need a touch, or raise LENDK_TIMEOUT. | Ask the user to run 'lendk unlock KEY' in a terminal, then retry.
  map (125): Fix the line, then run: lendk check | Stop and ask the user.
  map (125): Define it first: lendk add @GROUP KEY... | Stop and ask the user.
  unmapped (125): Map it: lendk add CMD KEY..., or name keys: lendk run KEY... -- CMD | Stop and ask the user.
  missing-key (125): Add it: pass insert env/KEY | Stop and ask the user.
  missing-key (125): Create it with lendk add, or name the keys to unlock. | Stop and ask the user.
  missing-key (125): Add a mapped key with pass insert, then retry. | Stop and ask the user.
  missing-key (125): Set it: pass edit env/KEY | Stop and ask the user.
  decrypt (125): See gpg's error: lendk unlock KEY | Ask the user to run 'lendk unlock KEY' in a terminal, then retry.
  unsafe (125): Fix it: chmod go-w PATH, or recreate it as your own | Stop and ask the user.
  write (125): Fix it, then run: lendk sync | Stop and ask the user.
  upgrade (125): Retry; on a slow connection raise LENDK_TIMEOUT. | Stop and ask the user.
  upgrade (125): Upgrade lendk the way it was installed. | Stop and ask the user.
  upgrade (125): Fix it, then run: lendk upgrade | Stop and ask the user.
  exec (126): Fix it, or unmap it: lendk rm CMD | Stop and ask the user.
  not-found (127): Install it, or unmap it: lendk rm CMD | Install CMD, or ask the user.
  lendk-missing (127): The user must reinstall lendk from its project repository, then run: lendk sync | The user must reinstall lendk from its project repository, then run: lendk sync
```

The first FIX shows in a terminal, the second without one.

- A mapped command runs without its key: `lendk check NAME`. Usually the shim directory is missing from PATH or another entry shadows it; rerun the matching `lendk init`.
- `locked` from a script, cron or an agent: run `lendk unlock` in a terminal.
- `timeout`: a hardware token may be waiting for a touch, or gpg-agent is stuck; raise `LENDK_TIMEOUT` or run `lendk unlock KEY` to see gpg's own prompt.
- `unsafe`: the map, its directory or the shim directory is writable by others or owned by someone else.
- `upgrade`: lendk is unchanged. The TEXT names the cause; see [Upgrade](#upgrade).

## Agent contract

- The `lendk: CLASS:` line on stderr is the contract. Act on the class; exit codes are hints and collide with the target's own codes.
- On `locked`, `timeout` or `canceled`, stop and ask a human to run `lendk unlock` in a terminal. Do not retry in a loop.
- Never run `pass`, `lendk add`, `lendk rm`, or `lendk run` with key names, and never print the environment. Relay the FIX to the user instead.
- Run commands as usual: `gh pr list`, not `lendk run -- gh pr list`.
- Run `lendk upgrade` only when the user asks, and never set `LENDK_INSTALL_BASE_URL`.
- `install.sh --skill-dir DIR` copies the lendk agent skill, which teaches all of this, to `DIR/lendk`.

## Requirements

- bash 4.4 or later
- GnuPG 2.4 or later
- pass 1.7 or later, with a store initialized by `pass init`
- POSIX utilities
- tar, gzip, `sha256sum` or `shasum`, and curl or wget, for `lendk upgrade` only
- `git` and `make` to install from source

lendk supports Linux and macOS; CI runs the full test suite on both. On macOS it needs bash and GnuPG from Homebrew (`brew install bash gnupg pass`), since the system bash is 3.2. Homebrew's bash must come first on the login PATH: `/etc/profile` puts `/usr/bin` first, so keep `eval "$(brew shellenv)"` in `~/.profile` (or `~/.bash_profile`) and `~/.zprofile`, above lendk's blocks. Development needs Docker for `make check-docker` and `uv` for shellcheck; `make deps` fetches bats-core.

On macOS, after a passphrase prompt inside a pipeline whose neighbor reads the terminal, such as `gh pr view | less`, the interactive bash can still show that neighbor as stopped; `fg` resumes it.

## License

MIT. See [LICENSE](LICENSE).
