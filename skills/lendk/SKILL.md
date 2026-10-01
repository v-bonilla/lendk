---
name: lendk
description: Use when a machine uses lendk to give API keys stored in pass to commands, when a command fails with a "lendk:" line on stderr, when a command lacks an API key it needs, or when the user asks to add, map, rotate or remove an API key, set up lendk on Linux or macOS, or uninstall it.
---

# lendk

The lendk CLI keeps API keys in pass and gives each one only to the commands mapped to it, only while they run. The user types `gh`; `gh` gets `GH_TOKEN`; nothing else does, the shell and you included.

## Mental model

- **Store**: each key is a pass entry `env/KEY` (prefix `LENDK_PREFIX`, default `env`). Its first line is the value.
- **Map**: `~/.config/lendk/map` (or `LENDK_MAP`) says which command gets which keys. One entry per line, `#` starts a comment:
  ```
  @aws        AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  gh          GH_TOKEN
  terraform   @aws CLOUDFLARE_API_TOKEN
  ```
  `@NAME KEY...` defines a group; `CMD WORD...` maps a command, WORD being a key or `@NAME`.
- **Shims**: one small `sh` script per mapped command in `~/.local/share/lendk/shims` (or `LENDK_SHIMS`), first on PATH. A shim runs `lendk run -- CMD`, which reads the map, finds the real CMD later on PATH, decrypts the keys, exports them and execs CMD.
- **pass and gpg-agent**: every call decrypts through pass. While gpg-agent holds the passphrase, calls succeed without a prompt; otherwise they fail with `locked` when there is no terminal.
- A key already set in the caller's environment wins, so `GH_TOKEN=x gh` overrides it.

Run mapped commands as usual: `gh pr list`, never `lendk run -- gh pr list`.

## Verbs

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

Examples, for the user to run or for you to run when the hard rules allow:

```
lendk check                           # safe for you: never decrypts
lendk check gh                        # why does gh lack its key?
lendk sync                            # safe for you after the user edited the map
lendk --help                          # name lists, classes, environment variables
lendk add gh GH_TOKEN                 # user: map gh to GH_TOKEN and write its shim
lendk add @aws AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
lendk add terraform @aws CLOUDFLARE_API_TOKEN
lendk rm gh                           # user: unmap gh and remove its shim
lendk rm terraform CLOUDFLARE_API_TOKEN
lendk run OPENAI_API_KEY -- ./script.sh   # user: one run with named keys
lendk unlock                          # user, in a terminal: cache the passphrase
lendk init sh                         # print the PATH block for a login file
```

`add` refuses guarded commands (shells, interpreters, launchers, package tools, agent CLIs) without `--force`, because their keys reach every program they run.

## Error contract

Every failure is one stderr line:

```
lendk: CLASS: TEXT. FIX
```

The class is the contract. Exit codes are hints only: after exec, the command's own status passes through and can collide with them. Without a terminal, FIX is the non-interactive variant, written for you. Act on the class:

| Class | Exit | What to do |
|---|---|---|
| `usage` | 2 | Fix the invocation; see `lendk --help`. |
| `guarded` | 2 | Stop and ask the user; only they decide on `--force`. |
| `unsupported` | 125 | Stop and ask the user: bash 4.4+ or GnuPG 2.4+ is missing from PATH. |
| `locked` | 120 | Stop. Ask the user to run `lendk unlock KEY` in a terminal, then retry once. |
| `canceled` | 120 | Stop and ask the user; someone dismissed the passphrase prompt. |
| `timeout` | 120 | Stop. Ask the user to run `lendk unlock KEY` in a terminal; a hardware token may need a touch. |
| `map` | 125 | Stop and ask the user; show them the line `lendk check` reports. |
| `unmapped` | 125 | Stop and ask the user whether to map the command. |
| `missing-key` | 125 | Stop. Tell the user to add it with `pass insert env/KEY`. |
| `decrypt` | 125 | Stop. Ask the user to run `lendk unlock KEY` in a terminal to see gpg's error. |
| `unsafe` | 125 | Stop and ask the user; a file or directory is writable by others. |
| `write` | 125 | Stop and ask the user; fix the reported path, then `lendk sync`. |
| `exec` | 126 | Stop and ask the user; the target exists but cannot run. |
| `not-found` | 127 | Install the command, or ask the user. |
| `lendk-missing` | 127 | Stop. The user must reinstall lendk, then run `lendk sync`. |

Never retry `locked`, `timeout` or `canceled` in a loop. Every failure stops before the command starts, so a retry after the fix is safe.

`lendk: notice: TEXT.` lines report a change or a risk, never a failure.

## Hard rules

- Never run `pass show`, `pass` with any key, or `gpg --decrypt`. Never read or print a key value.
- Never print the environment: no `env`, `printenv`, `export -p`, `set`, `cat /proc/*/environ`, and no `echo "$KEY"`.
- Never run `lendk add`, `lendk rm` or `lendk run` with key names on your own initiative. Propose the exact command and let the user run it or approve it.
- Never use `--force` unless the user asked for it.
- On `locked`, stop and ask a human to run `lendk unlock` in a terminal. Do not try to unlock it yourself.
- Never edit the map, the shim files or GnuPG settings by hand without the user's approval.
- One exemption: an installation test the user approved, with a throwaway key and exactly these commands:
  ```
  printf 'lendk-test\n' | pass insert -m env/DEMO_TOKEN
  lendk run DEMO_TOKEN -- sh -c 'test -n "$DEMO_TOKEN" && echo received'
  pass rm -f env/DEMO_TOKEN
  ```

`lendk check`, `lendk --help`, `lendk --version` and printing `lendk init` are always safe to run. `lendk sync` is safe too: it only rewrites lendk's own shims to match the map, which is not editing them by hand.

## Common questions

**Add a tool.** Store the key, then map it (the user runs both):
```
pass insert env/OPENAI_API_KEY
lendk add llm OPENAI_API_KEY
```
Keys that travel together go in a group: `lendk add @aws AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY`, then `lendk add aws @aws`.

**Rotate a key.** `pass edit env/GH_TOKEN`. The next call uses the new value; no sync. Running processes keep the old one.

**A command runs without its key.** Run `lendk check NAME`. Usually the shim directory is missing from PATH or a later PATH prepend (virtualenv, nvm, mise) shadows it; the fix is the matching `lendk init` block (see [references/setup.md](references/setup.md)). Also check:
- the caller bypasses PATH (absolute path, `npx`, `npm run`, `uv run`, cron, systemd units, MCP configs): wrap it as `lendk run -- CMD` or `lendk run KEY -- CMD`, with lendk by absolute path where PATH is not set up;
- a git credential helper names gh by absolute path: use `!lendk run -- gh auth git-credential`;
- the key is already set in the environment, which wins over the store.

**Calls from cron, agents or scripts fail with `locked`.** gpg-agent has no cached passphrase. The user runs `lendk unlock` in a terminal; cache lifetime is `default-cache-ttl` and `max-cache-ttl` in `~/.gnupg/gpg-agent.conf`.

**Decrypts are slow.** GnuPG's default `s2k-count` re-runs a costly key derivation on every decrypt. See [references/setup.md](references/setup.md); the user decides, since it weakens the key file against offline guessing.

**Set up Linux or macOS, or uninstall.** See [references/setup.md](references/setup.md).

## Troubleshooting

Start with `lendk check`. It never decrypts, and reports map errors, missing keys, missing commands, missing or stale shims, a shim directory absent from PATH, shims shadowed by an earlier PATH entry, and unsafe permissions, each with a fix. It exits 1 when anything it shows has a problem. Relay its fixes to the user; run only the safe verbs yourself.

It is not a sandbox: any process running as the user can call pass while gpg-agent is unlocked. It keeps keys out of ambient environments, rc files and your context.
