# PATH shims, not a prefix command

The common habit, `export OPENAI_API_KEY=...` in a shell rc file, gives every key to every process, agents and install scripts included, and puts values in plaintext into dotfile repositories. pass fixes storage at rest, not delivery. lendk adds delivery and leaves storage to pass: `lendk sync` writes one shim per mapped command into the shim directory, which comes first on PATH, and the shim runs `lendk run -- CMD`, which injects that command's keys and execs the target. pass stays the only store, and lendk only reads it. Per-command least privilege then needs no prefix: every process that finds a mapped command through PATH gets its keys, whether or not it read an rc file, and humans and agents type `gh` as before. Only lendk makes that the default; every tool below needs a prefix command or scopes keys wider than one command.

## Considered Options

- Exports in an rc file: every process the shell starts gets every key, and the values sit in plaintext in a file that dotfile repositories copy. A subshell or session that holds keys has the same flaw, so lendk offers none.
- `env KEY=$(pass show ...) cmd`: the value is an argument of `env`, which `ps` shows.
- Shell aliases: scripts and agents never see them.
- `.env` files and direnv: every process in a directory gets every key of that directory.
- A prefix command such as `x run -- cmd`: humans forget it, and agents do not know it.
- gopass `env` (a whole subtree), fnox and secretspec (manifests), CyberArk summon, Infisical `run` and OpenBao agent exec (servers), sops `exec-env` (an encrypted file): each needs a prefix command or scopes keys wider than one command.
- lendk writing to the store, or a store of its own: the human already keeps keys in pass with `pass insert` and `pass edit`. Since lendk reads the value at each run, rotating a key is one `pass edit` with no follow-up step.
- A link to lendk in the shim directory, with lendk dispatching on its own name (`argv[0]`): it saves one `/bin/sh` start per call, a median 1.2 ms over a direct exec on Linux with dash. But bash, dash, zsh and `execvp` skip a symlink whose lendk is gone and run the next copy of the command on PATH, without its keys and with no class line, where a script shim prints `lendk-missing` and exits 127. `resolve`'s guard against a foreign shim directory and the installer's uninstall find a shim by its second line, which a link lacks. A hard link never dangles, but fails across file systems and keeps a replaced lendk running until the next sync.

## Consequences

- The shim directory must come before every other copy of a mapped command on PATH, for every kind of caller: see [ADR 0002](0002-login-level-path-setup.md).
- A caller that bypasses PATH gets no keys: see [ADR 0008](0008-same-user-threats-out-of-scope.md). `lendk run -- CMD` by absolute path serves cron, systemd units and MCP server settings.
- Real binaries still resolve in PATH order after the shim directory, so a virtualenv's copy of a command is the one the shim runs.
