# lendk setup, PATH, upgrade and uninstall

## Install

```
curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash -s -- --yes
```

The last output line is `lendk-install: ok: TEXT` or `lendk-install: CLASS: TEXT`:

| Class | Exit | Meaning |
|---|---|---|
| `usage` | 2 | Bad option; see `--help`. |
| `unsupported-os` | 1 | Only Linux and macOS are supported. |
| `missing-deps` | 1 | The line names the package manager command. Ask the user before rerunning with `--install-deps`, which may use sudo. When that fails without a terminal, the line names the command for the user to run by hand, after `sudo -v`. |
| `download` | 1 | Network failure, or no release for `--version`. |
| `checksum` | 1 | The download does not match `SHA256SUMS`; nothing was installed. Never bypass it. |
| `install` | 1 | Cannot write `PREFIX/bin`, or a file the installer did not write is in the way. |
| `path` | 1 | Cannot edit a login file. |

Options: `--version X.Y.Z`, `--prefix DIR`, `--yes`, `--install-deps`, `--no-modify-path`, `--skill-dir DIR`, `--uninstall`, `--help`.

When the pass store is not initialized, the installer prints the `gpg --quick-generate-key` and `pass init` steps. The user runs them in their own terminal, since gpg asks for a new passphrase.

## PATH

A shim works when PATH lists the shim directory before any other copy of the command. The installer adds one `# >>> lendk-install >>>` block to the login files; by hand, `lendk init` prints the blocks:

```
lendk init sh >> ~/.profile     # bash logins and desktop sessions (~/.bash_profile when it exists)
lendk init sh >> ~/.zshenv      # every zsh, zsh -c included
lendk init bash >> ~/.bashrc    # optional prompt hook; zsh: lendk init zsh >> ~/.zshrc
lendk init systemd > ~/.config/environment.d/99-lendk.conf
```

- Linux: the environment.d file covers systemd user services and desktop sessions. Changes apply at the next login.
- macOS: needs `brew install bash gnupg pass`, since the system bash is 3.2. Homebrew's bash must come first on the login PATH: keep `eval "$(brew shellenv)"` in `~/.profile` (or `~/.bash_profile`) and `~/.zprofile`, above lendk's blocks. Add `lendk init sh` to `~/.zprofile` too, since `path_helper` reorders PATH after `~/.zshenv`. Apps launched from the Dock read none of these files.
- Check from a new login shell: `bash -lc 'command -v lendk; printf "%s\n" "$PATH"'` shows lendk, and the shim directory first.

## Callers that skip PATH

```
# crontab
0 * * * * /home/alice/.local/bin/lendk run -- gh repo sync
```

```
{ "command": "/home/alice/.local/bin/lendk", "args": ["run", "--", "some-mcp-server"] }
```

Git credential helper for GitHub, replacing what `gh auth setup-git` wrote:

```
for host in github.com gist.github.com; do
  git config --global --replace-all credential.https://$host.helper ''
  git config --global --add credential.https://$host.helper '!lendk run -- gh auth git-credential'
done
```

## Decrypt speed

With the user's approval, in `~/.gnupg/gpg-agent.conf`:

```
s2k-count 8388608
```

Then `gpgconf --reload gpg-agent` and `gpg --passwd KEYID` with the same passphrase. Only with a strong passphrase: a copied key file becomes about 20 times faster to attack.

## Upgrade

Only when the user asks:

```
lendk upgrade
```

- It downloads the latest release, checks it against `SHA256SUMS`, renames the release's file over the installed `lendk`, and runs `lendk sync`. It prints `upgraded lendk A.B.C to X.Y.Z at PATH`, or `lendk A.B.C is up to date: the latest release is X.Y.Z`.
- It leaves the map, the store, the login files, the environment.d file and a skill copy as they are, reads no key and never prompts.
- An argument is `usage`. Any other failure is one `lendk: upgrade:` line, and the installed file is unchanged. Stop and relay the line: the cause is a failed or slow download (`LENDK_TIMEOUT` bounds it), a checksum mismatch, a release without a usable lendk, an install another tool manages (a symlink, a version that is not a release's, or a directory the user cannot write), or a missing tar, gzip, `sha256sum` or `shasum`, curl or wget.
- Never set `LENDK_INSTALL_BASE_URL`: it moves the trust in the release to whoever serves that URL. When the user set it, a notice names the base.
- Rerunning the installer refreshes PATH setup, refreshes a skill copy with `--skill-dir DIR`, and installs a chosen release with `--version X.Y.Z`:
  ```
  curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash -s -- --yes --skill-dir DIR
  ```
- From a checkout: `git pull`, then `make install`.

## Uninstall

```
curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash -s -- --uninstall
```

Add `--skill-dir DIR` to remove the copied skill too. It removes the installer's login file blocks, the environment.d file, lendk's shims and the installed `lendk`, never the map or the pass store. From a source install: delete the `# >>> lendk >>>` blocks and the environment.d file, then `make -C lendk uninstall`.
