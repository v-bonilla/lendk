# Same-user threats are out of scope, and lendk is no sandbox

lendk protects against ambient exposure: keys reach only mapped commands, `lendk run` targets and their descendants. It also keeps values in plaintext out of rc files, keeps keys out of argv, files and the environment of its helpers, and keeps agents from waiting on prompts. It sandboxes nothing. The threats a sandbox would answer run as the same user, and against them lendk has no boundary to hold: while gpg-agent holds the passphrase, any same-user process, an agent included, can run `pass show`, read `/proc/PID/environ`, edit the map, the shims or PATH, or replace lendk itself. lendk keeps keys out of an agent's context; it does not stop an agent that fetches them. Outside the model are:

- same-user processes, as above;
- a target itself, which holds its keys and can print them, and its descendants, for their lifetime; running processes keep old values after a rotation;
- root;
- callers that bypass PATH, such as an absolute path, `npx`, `npm run`, `uv run` or a service. They run without lendk's keys and fail, or act under the tool's own stored credentials, such as gh's `hosts.yml` or `~/.aws/credentials`.

## Considered Options

- A sandbox around the target or the agent: the processes it would have to fence are every program that runs as the same user, not lendk's own, and fencing them needs root or platform features beyond the POSIX utilities lendk runs on ([ADR 0010](0010-one-bash44-file-posix-utils.md)). lendk installs and runs without root.

## Consequences

- A mapped command that runs other programs hands its keys to all of them, so mapping one takes a deliberate step: see [ADR 0009](0009-guarded-commands-and-denied-names.md).
- The README's Security model states these limits for humans deciding whether to trust lendk.
