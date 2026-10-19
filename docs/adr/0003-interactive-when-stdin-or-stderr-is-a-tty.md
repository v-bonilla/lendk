# A call is interactive when stdin or stderr is a terminal

A passphrase prompt nobody sees makes an agent wait, so lendk decides per call whether a prompt can reach a human. A call is interactive when `LENDK_PROMPT=allow`, or when `LENDK_PROMPT` is unset or `auto` and stdin or stderr is a terminal; `never` is never interactive. Testing stderr as well as stdin keeps git credential helpers interactive: git runs them with stdin a pipe and stderr the terminal.

## Considered Options

- Testing stdin alone: a credential helper such as `!lendk run -- gh auth git-credential` could never prompt, though a human sits at the terminal.
- Probing `/dev/tty`: agents launched from a terminal still have one, so their calls would count as interactive, and a curses pinentry would seize that terminal.

## Consequences

- An agent that runs commands in a pseudo-terminal counts as interactive. `LENDK_TIMEOUT` bounds its wait, and `LENDK_PROMPT=never` makes it fail fast with `locked` instead.
- Without a terminal, `lendk unlock` cannot prompt, so it is a probe: on a locked store it gives `locked`.
