# The shim directory goes first on the login-level PATH

A shim works only when PATH lists the shim directory before any other copy of its command, and most callers never start an interactive shell: `bash -c` reads no rc file, `zsh -c` reads only `~/.zshenv`, and desktop apps and systemd user services inherit the login environment. So lendk's PATH setup works at the login level. `lendk init sh` goes into `~/.profile` (or `~/.bash_profile` when it exists) and `~/.zshenv`, and `lendk init systemd` into `~/.config/environment.d/99-lendk.conf`. Each block holds the absolute shim directory, so the file that receives it needs no `lendk` on PATH, and it moves that directory to the front of PATH. In `~/.zshenv` that covers every `zsh -c`, even under a harness that prepended its own directory.

## Considered Options

- Only `~/.bashrc` or `~/.zshrc`: interactive shells see the shims, but `bash -c`, `zsh -c`, desktop apps and systemd user services do not, and agents and editors start commands that way.
- Appending the shim directory to PATH: an earlier copy of the command wins and runs without its keys.
- A prompt hook alone: it runs only in interactive shells. `lendk init bash` and `lendk init zsh` keep it as an optional extra that repeats the move before every prompt, against version managers and virtualenvs that prepend PATH later.
- A system-wide file such as `/etc/environment`: it needs root, and lendk installs, upgrades and uninstalls without root.

## Consequences

- The environment.d file sorts after `99-environment.conf`, which Ubuntu links to `/etc/environment` and which sets PATH. A file that sorted earlier would see its PATH replaced.
- Desktop apps see the shims after the next desktop login, since they inherit the environment of the session that started them.
- On macOS, `path_helper` reorders PATH after `~/.zshenv`, so zsh logins also need the block in `~/.zprofile`.
