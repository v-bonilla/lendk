# Values stay in memory until exec, and the backend gets an allowlisted environment

A value must reach the target's environment and nothing else: no output, file, argv, or environment of another process. lendk keeps values in unexported shell variables until every decrypt of the call has succeeded, then exports them just before it execs the target, with only builtins in between. The backend job reads each store entry by running pass under `env -i`, with stdin `/dev/null` and an environment built from scratch: PATH without the shim directory, `PASSWORD_STORE_GPG_OPTS` as lendk sets it, `GPG_TTY`, and the caller's locale, terminal, display, GnuPG and pass variables that `allow_env` in `bin/lendk` lists. Keys, exported functions, `BASH_ENV` and `ENV` never reach pass, gpg, or a gpg-agent that gpg starts. That matters three ways: gpg-agent is a daemon that keeps the environment it started with long after the call; pass is a bash script, so an exported function or `BASH_ENV` would run the caller's code next to every value it reads; and under a nested shim the caller holds the keys of the outer command, which the inner backend must not see.

## Considered Options

- Exporting each value as it is read: the backend read of the second key would see the first value in its environment.
- Here-strings or here-documents to move a value: bash before 5.1 backs them with temporary files, so the value would reach the disk.
- A value in argv: `ps` shows it to other processes.
- Letting the backend inherit the caller's environment: it would carry other keys, exported functions and `BASH_ENV` into pass, gpg and gpg-agent.

## Consequences

- Values cross from the backend job to the main shell through a pipe and live nowhere else. The temporary directory, mode 0700 with files 0600, holds each key's status and stderr files and the job's PID, never a value. The status descriptor exists only inside the job's read, so neither the main shell nor the target holds it.
- lendk runs `set +x +v` before it reads values, so `bash -x` or an exported `SHELLOPTS=xtrace` traces none. The caller's `xtrace` and `verbose` come back last, just before exec.
- Values are exported only after the last decrypt succeeds, and any failure before exec ends the call before the target starts.
