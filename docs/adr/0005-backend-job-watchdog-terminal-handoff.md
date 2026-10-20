# One bound for a call's helpers, kept by a watchdog

`LENDK_TIMEOUT` bounds all helper work of a call, and no process of the call outlives it, even when a process a helper started ignores TERM: a call ends no later than `LENDK_TIMEOUT` + 2 s, cleanup included. A helper is any program lendk starts: `pass show`, `gpg --version`, and `upgrade`'s tools and the staged run of the new file. The bound covers every key of a call together, from the GnuPG check to the last read; its default is 60 s in an interactive call and 10 s otherwise. lendk keeps it with a watchdog and process groups, and installs no signal handler:

- The watchdog W is a fork of lendk, started before the first helper, in a process group of its own, so a signal aimed at lendk's group misses it. It sets its stdio to `/dev/null` and ignores the terminating and job-control signals.
- Each helper leads a process group of its own, so it is a background group on the terminal. Between fork and exec it writes its PID to W over a close-on-exec pipe, then calls `setpgid`: a KILL before the write still finds the helper in lendk's group, and after it W knows the helper.
- Every read and every wait of lendk polls against one deadline. Past it, lendk sends TERM and CONT to the helper's group and to the helper, sends KILL after 0.3 s, reaps the helper and fails with `timeout`.
- When lendk ends without telling W it is done, through a KILL or a signal to it or its group, W sees its pipe close. It ends the last helper's group the same way and removes the call's temporary directory and, in `lendk upgrade`, the staged file.
- On success or failure, lendk tells W it is done and reaps it before exec or exit, so no watchdog outlives the call or becomes the target's child.

A backend never gets the terminal. A loopback passphrase prompt calls `tcsetattr` from a background group, which stops the backend with SIGTTOU; a backend stopped on the terminal stays stopped until the bound and gives `timeout`. So a call that cannot prompt, because it is not interactive or because gpg is set to `pinentry-mode loopback` in `gpg.conf` or `PASSWORD_STORE_GPG_OPTS`, gives the backend `--pinentry-mode error`, and gets `locked` instead of a stopped backend ([ADR 0004](0004-fail-fast-classify-by-status-code.md)). Every other pinentry runs under gpg-agent and needs no terminal from lendk.

## Considered Options

- `timeout(1)` or `setsid`: macOS lacks both, and a helper in a session of its own would escape the caller's terminal signals.
- Signal handlers in lendk that end the helpers: a KILL runs no handler, and a handler that runs between the first decrypt and exec widens the window in which a value sits in memory.
- Handing the terminal to a backend for a loopback prompt, as 1.x did: it took job control in lendk, a terminal-owner test, and a CONT to lendk's own group that also resumed a sibling the caller stopped on purpose.

## Consequences

- Killing gpg makes gpg-agent interrupt a waiting pinentry, which stays a zombie until gpg-agent reaps it. Ending the helper's group ends the prompt, and the tests count a zombie as gone.
- A user whose gpg prompts through loopback gets `locked` from every call, `lendk unlock` included, until a pinentry outside the terminal primes gpg-agent's cache.
- `lendk upgrade` renames the staged file while W lives, so a KILL at any moment still finds W to remove it.
