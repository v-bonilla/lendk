# One bash 4.4 file on POSIX utilities

lendk is one executable bash file, `bin/lendk`, which needs bash 4.4, GnuPG 2.4, pass 1.7 and POSIX utilities at run time, and nothing else. Its opening lines, up to the version test, parse and run in bash 3.2 and any POSIX sh, so an older shell, such as macOS's own bash 3.2, gets a `lendk: unsupported:` line with its FIX instead of a syntax error. The reasons:

- One file keeps install, upgrade and audit simple: install copies one file, upgrade renames one file over it, and an audit reads one file.
- pass is itself a bash script, so bash adds no runtime that pass does not already need.
- bash 4.4 is the floor for the coproc and job-control behavior the watchdog relies on, measured on bash 4.4 and 5 ([ADR 0005](0005-backend-job-watchdog-terminal-handoff.md)), and for shell features lendk uses throughout, such as `${NAME@a}` and empty arrays under `set -u`.
- Debian, Ubuntu and Fedora ship a newer bash, and macOS gets one from Homebrew. Linux is the first tier: Debian 13, Ubuntu 24.04 and later, and current Fedora.

GnuPG 2.4 is the version whose pinentry modes and status codes the fail-fast path was measured on ([ADR 0004](0004-fail-fast-classify-by-status-code.md)). External utilities are POSIX ones, with options GNU, BSD and busybox share, plus `mktemp [-d] TEMPLATE`, plain `readlink` and fractional `sleep`, so the one file runs unchanged on Linux, with GNU or busybox userland, and on macOS. `lendk upgrade` alone also needs tar, gzip, `sha256sum` or `shasum`, and curl or wget.

## Considered Options

- Several files, such as a library directory beside the script: install and upgrade would have to move them together, while a rename replaces one file whole.
- bash 3.2, the system bash of macOS: it lacks the associative arrays, `coproc` and `${NAME@a}` that lendk uses.
- Utilities outside POSIX, such as `timeout`, `flock`, `setsid`, `stat` or `readlink -f`: each is missing or differs on macOS or busybox. The repo lint, `test/lint-repo.bash`, rejects them in `bin/lendk`.

## Consequences

- `lendk run` and `lendk unlock` check the version of the gpg pass uses, `gpg2` when it is on PATH and `gpg` otherwise, and give `unsupported` below 2.4, before the first decrypt.
- When the first bash on PATH is older than 4.4, the installer's login PATH block puts a directory holding a newer bash ahead of it.
