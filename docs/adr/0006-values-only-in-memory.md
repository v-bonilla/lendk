# Values stay in memory until exec, and the backend gets an allowlisted environment

A value must reach the target's environment and nothing else: no output, file, argv, or environment of another process. lendk keeps values in its one `Plaintext` buffer until every decrypt of the call has succeeded, then points the target's `envp` into that buffer and execs the target, with no helper started in between. The helpers module, `src/helpers.rs`, starts pass for each store entry with stdin `/dev/null` and an environment built from scratch: PATH without the shim directory, `PASSWORD_STORE_GPG_OPTS` as lendk sets it, `GPG_TTY`, and the caller's locale, terminal, display, GnuPG and pass variables on its allowlist. The download and unpack tools of `lendk upgrade` get that allowlist plus the proxy and certificate variables a download needs, which the same module lists; the staged lendk it runs gets the allowlist alone. Keys, exported functions, `BASH_ENV` and `ENV` never reach pass, gpg, or a gpg-agent that gpg starts. That matters three ways: gpg-agent is a daemon that keeps the environment it started with long after the call; pass is a bash script, so an exported function or `BASH_ENV` would run the caller's code next to every value it reads; and under a nested shim the caller holds the keys of the outer command, which the inner backend must not see.

## Considered Options

- Exporting each value into lendk's own environment as it is read: the pass read of the second key would see the first value.
- A value in argv: `ps` shows it to other processes.
- Letting the backend inherit the caller's environment: it would carry other keys, exported functions and `BASH_ENV` into pass, gpg and gpg-agent.

## Consequences

- Values cross from pass to lendk through a pipe read with `read(2)` into the buffer, and live nowhere else. The temporary directory, mode 0700 with files 0600, holds each key's status and stderr files, never a value. The status descriptor is open only in the pass it is given to, so the target never holds it.
- lendk runs no shell, so a caller's `bash -x` or `SHELLOPTS=xtrace` traces nothing of lendk's.
- `envp` is built only after the last decrypt succeeds, and any failure before exec zeroes the buffer and ends the call before the target starts.
- `clippy.toml` bans setting a child's environment outside the helpers module, so a new tool or variable of any helper is a change to that one module.
