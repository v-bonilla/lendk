# `lendk upgrade` trusts the HTTPS release and replaces one file by a rename

`lendk upgrade` replaces lendk, which reads every mapped key, so what it trusts and how it writes matter more than in most tools. It trusts what the installer trusts, the project's GitHub releases over HTTPS, and nothing new. It fetches the latest release's `lendk.tar.gz` and `SHA256SUMS` and replaces lendk's own file, the path lendk was invoked by, with the archive's `bin/lendk`, by a rename. `SHA256SUMS` comes from the same release, so its checksum catches a corrupt or cut-short download, not a compromised release or account. The upgrade changes as little as it can:

- It refuses, before any fetch, an install it does not own: a symlink, which means another tool manages versions; a file that is not lendk's own, by its second line; a version that is not a release's `X.Y.Z`; or a directory the human cannot write. Its FIX says to upgrade lendk the way it was installed.
- Before anything is replaced, the archive's SHA-256 must equal the one `SHA256SUMS` lists; the archive must hold exactly one `lendk-X.Y.Z/bin/lendk`, whose second line is lendk's own; and that file, run with `--version` by the bash running the upgrade, must print exactly `lendk X.Y.Z`. Only that one file leaves the archive.
- Versions compare number by number, and a release that is not higher changes nothing, so an install ahead of the latest release is never downgraded.
- The new file is staged beside lendk's own, on the same file system, with mode 0755, and renamed over it, never written in place. bash reads a script as it runs, so the path holds the old file or the new one, whole: a call running across the rename finishes on the old file. No write lock guards the rename, and two upgrades at once both succeed.
- After the rename lendk runs none of its old code: it execs the new file by its path with `sync`, as a shim runs it, so a new file that does not run under the first bash on PATH shows at once. `sync` holds the write lock as usual.
- It writes no login file, environment.d file, map, store entry or skill copy, and never fetches or runs `install.sh`.

## Considered Options

- Signature checks: a signature adds trust only through a signer's public key that the human gets some other way than the release itself, and the first install already trusts the same project over HTTPS. lendk checks none, and the README says so.
- Choosing a release, rolling back or downgrading: `install.sh --version X.Y.Z` installs any release, so `lendk upgrade` takes no arguments and only moves forward.
- Writing the new bytes over the old file: a running lendk, which bash reads as it goes, could execute a mix of both.
- Replacing a symlink's target: it would fight the tool that manages the versioned directories. With versioned directories behind a stable symlink, the human installs the new version beside the old, moves the symlink, and runs `lendk sync` once through it.
- Refreshing PATH setup or a skill copy: rerunning `install.sh` does that, so `lendk upgrade` replaces one file.

## Consequences

- `LENDK_TIMEOUT` bounds the fetch and the checks together, which run as a job under the watchdog of [ADR 0005](0005-backend-job-watchdog-terminal-handoff.md); a call stopped before the rename leaves lendk's file unchanged.
- `LENDK_INSTALL_BASE_URL` moves the trust to whoever serves that URL. It must start with `https://` or `file:///`, lendk names a set base in a notice, and an agent never sets it.
- The download tool reads the human's own configuration, such as `~/.curlrc`.
