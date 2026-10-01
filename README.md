# lendk

`export OPENAI_API_KEY=...` in a shell rc file gives every key to every process you start: AI coding agents, package install scripts, any tool you try once. lendk keeps your API keys in [pass](https://www.passwordstore.org/) and gives each one only to the commands that need it, only while they run. You type `gh`; `gh` gets `GH_TOKEN`; nothing else does. A shim per mapped command sits first on PATH, so shells, scripts, Python subprocesses and agents all get the same behavior with no prefix command.

## Key features

- Per-command keys: `gh` gets `GH_TOKEN`, and no other process gets any key.
- No prefix command: shims first on PATH serve shells, scripts, subprocesses and AI agents alike.
- Keys stay in pass, never in rc files, argv, files, logs or lendk's output.
- Built for agents: no hung passphrase prompts, one stable stderr class line per failure.
- `lendk check` finds shadowed shims, missing keys and PATH mistakes without decrypting.
- One bash file: no daemon, no cache of values, no network access, no telemetry.
- Linux and macOS, installed by a checksum-verifying script without root.

## Quick start

You need a GPG key and a pass store initialized for it; the installer prints the steps when the store is missing.

Four commands, bash on Linux:

<!-- quickstart -->
```
curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash
exec bash -l
pass insert env/GH_TOKEN
lendk add gh GH_TOKEN
```
<!-- quickstart -->

Command 2 starts a login shell, which reads the PATH block the installer added. Desktop apps see the shims after the next desktop login. For zsh, systemd and macOS, see [PATH setup](#path-setup).

Now `gh` gets `GH_TOKEN`, and `echo "$GH_TOKEN"` in your shell prints nothing.

## Installation

Install only from this repository.

### For humans

```
curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash
```

The installer downloads the latest release and its `SHA256SUMS`, verifies the checksum, and installs `lendk` into `~/.local/bin` without root. It checks for bash 4.4 or later, GnuPG 2.4 or later, pass, curl or wget, tar and a SHA-256 tool, and prints the package manager command for any that are missing. It then appends a `# >>> lendk-install >>>` block to your login file (`~/.bash_profile` or `~/.profile`, plus `~/.zshenv` for zsh and `~/.zprofile` for zsh on macOS) that puts `~/.local/bin` on PATH and the shim directory first, and on Linux with a systemd user session writes `~/.config/environment.d/99-lendk.conf`. It prints each change. Rerunning it upgrades lendk and changes nothing else.

Options go after `bash -s --`, for example `curl -fsSL .../install.sh | bash -s -- --yes`:

```
--version X.Y.Z    install release X.Y.Z instead of the latest
--prefix DIR       install into DIR/bin (default ~/.local)
--yes              never prompt (also implied when stdin is not a terminal)
--install-deps     run the package manager command for missing dependencies
--no-modify-path   leave login files and the environment.d file alone
--skill-dir DIR    copy the lendk agent skill to DIR/lendk
--uninstall        remove what this installer added, never the map or the pass store
```

Except with `--help`, the last line of its output is `lendk-install: ok: TEXT`, or `lendk-install: CLASS: TEXT` with CLASS one of `usage`, `unsupported-os`, `missing-deps`, `download`, `checksum`, `install` or `path`. `LENDK_INSTALL_BASE_URL` replaces `https://github.com/v-bonilla/lendk/releases`, for tests and mirrors: it must start with `https://` or `file:///`, and must serve `BASE/latest/download/lendk.tar.gz` and `BASE/latest/download/SHA256SUMS`, or `BASE/download/vX.Y.Z/` with the same two files for `--version X.Y.Z`.

With `--install-deps` and no terminal, sudo runs as `sudo -n` and fails when it needs a password; run `sudo -v` first, or run the printed command yourself.

Uninstall: `curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash -s -- --uninstall`. It removes its login file blocks, the environment.d file, lendk's shims and the installed `lendk`, never the map or the store.

#### From source

```
git clone https://github.com/v-bonilla/lendk
make -C lendk install                  # PREFIX defaults to ~/.local; DESTDIR is honored
```

`make install` renames a new file over the old one, so a running lendk keeps reading its copy.

Upgrade: `git pull`, then `make install`. With versioned install directories behind a stable symlink, run `lendk sync` once through the symlink.

Uninstall: delete the `# >>> lendk >>>` blocks from your rc files and the environment.d file, then `make -C lendk uninstall`. It removes lendk's shims, the shim directory and lendk's data directory if empty, and the installed file when it is lendk's, never the map, the store or your rc files.

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

## Daily use

```
lendk run [KEY|@GROUP...] -- CMD [ARG...]      # exec CMD with its mapped or the named keys
lendk add [--force] CMD|@GROUP KEY|@GROUP...   # map, then sync
lendk rm CMD|@GROUP [KEY|@GROUP...]            # unmap, then sync
lendk check [NAME...]                          # diagnose without decrypting
lendk sync                                     # write shims to match the map
lendk unlock [KEY|@GROUP...]                   # unlock in a terminal; probe elsewhere
lendk init sh|bash|zsh|systemd                 # print PATH setup
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
@aws        AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
gh          GH_TOKEN
terraform   @aws CLOUDFLARE_API_TOKEN    # trailing comment
```

- One entry per line; `#` starts a comment. `@NAME KEY...` defines a group; `CMD WORD...` maps a command, WORD being a key or `@NAME`.
- Groups inline in word order; duplicates are dropped, keeping the first.
- lendk refuses keys that steer lendk, pass, gpg, the shell or the loader, and refuses to map its own runtime.
- Guarded commands run other programs, so their keys reach everything they run. `lendk add` maps them only with `--force`, and prints a notice.

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
- No daemon, no cache of values, no network access, no telemetry. lendk writes only the map, the shim directory and its lock.

### Security model

lendk protects against ambient exposure: keys reach only mapped commands, `lendk run` targets and their descendants. It also keeps plaintext keys out of rc files and dotfile repos, and keeps agents from hanging on prompts.

It does not protect against:

- Other processes running as you. While gpg-agent holds your passphrase, any of them, an AI agent included, can run `pass show`, read `/proc/PID/environ`, or edit the map, the shims or PATH. lendk keeps keys out of an agent's context; it does not stop an agent that goes looking for them.
- A mapped command itself. It holds the key and can print it, as `gh auth token` does, so map only tools you trust with that key.
- Descendants of a mapped command, for their lifetime, and root. Running processes keep old values after a rotation.
- Callers that bypass PATH. They run without lendk's keys and fail, or act under the tool's own stored credentials, such as gh's `hosts.yml` or `~/.aws/credentials`.

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
  exec (126): Fix it, or unmap it: lendk rm CMD | Stop and ask the user.
  not-found (127): Install it, or unmap it: lendk rm CMD | Install CMD, or ask the user.
  lendk-missing (127): The user must reinstall lendk from its project repository, then run: lendk sync | The user must reinstall lendk from its project repository, then run: lendk sync
```

The first FIX shows in a terminal, the second without one.

- A mapped command runs without its key: `lendk check NAME`. Usually the shim directory is missing from PATH or another entry shadows it; rerun the matching `lendk init`.
- `locked` from a script, cron or an agent: run `lendk unlock` in a terminal.
- `timeout`: a hardware token may be waiting for a touch, or gpg-agent is stuck; raise `LENDK_TIMEOUT` or run `lendk unlock KEY` to see gpg's own prompt.
- `unsafe`: the map, its directory or the shim directory is writable by others or owned by someone else.

## Agent contract

- The `lendk: CLASS:` line on stderr is the contract. Act on the class; exit codes are hints and collide with the target's own codes.
- On `locked`, `timeout` or `canceled`, stop and ask a human to run `lendk unlock` in a terminal. Do not retry in a loop.
- Never run `pass`, `lendk add`, `lendk rm`, or `lendk run` with key names, and never print the environment. Relay the FIX to the user instead.
- Run commands as usual: `gh pr list`, not `lendk run -- gh pr list`.
- `install.sh --skill-dir DIR` copies the lendk agent skill, which teaches all of this, to `DIR/lendk`.

## Requirements

- bash 4.4 or later
- GnuPG 2.4 or later
- pass 1.7 or later, with a store initialized by `pass init`
- POSIX utilities
- `git` and `make` to install from source

lendk supports Linux and macOS; CI runs the full test suite on both. On macOS it needs bash and GnuPG from Homebrew (`brew install bash gnupg pass`), since the system bash is 3.2. Homebrew's bash must come first on the login PATH: `/etc/profile` puts `/usr/bin` first, so keep `eval "$(brew shellenv)"` in `~/.profile` (or `~/.bash_profile`) and `~/.zprofile`, above lendk's blocks. Development needs Docker for `make check-docker` and `uv` for shellcheck; `make deps` fetches bats-core.

On macOS, after a passphrase prompt inside a pipeline whose neighbor reads the terminal, such as `gh pr view | less`, the interactive bash can still show that neighbor as stopped; `fg` resumes it.

## License

MIT. See [LICENSE](LICENSE).
