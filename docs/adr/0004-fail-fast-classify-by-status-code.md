# Fail fast with `--pinentry-mode error`, and classify by gpg's status codes

A non-interactive call must never wait on a pinentry nobody sees, and must tell its caller in one line why a decrypt failed. Every backend read appends `--status-fd` to `PASSWORD_STORE_GPG_OPTS`, after the human's own value, and a non-interactive call also appends `--pinentry-mode error`. lendk then classifies a failure by the low 16 bits of the first `ERROR` status value, never by gpg's text: in a non-interactive call, codes 85 and 99 are `locked`. Measured with GnuPG 2.4.4, pass 1.7.4 and a recording `pinentry-program`: on a locked store, `--pinentry-mode error` makes gpg exit 2 in about 30 ms with the status `ERROR pkdecrypt_failed 67108949` (code 85) and launch no pinentry, in both of pass's branches (with `gpg2` on PATH, where pass adds `--batch`, and without); while gpg-agent holds the passphrase, it decrypts.

## Considered Options

- `--batch` alone: gpg still launches pinentry.
- `--pinentry-mode cancel`: gpg gives code 99, the code of a human's Cancel, so a locked store would look like a refusal.
- Parsing gpg's messages: they are translated, and the backend gets the caller's `LANG` and `LC_*`, so the text changes with the locale.

## Consequences

- With stdin piped, pass sends pinentry `ttyname=not a tty`, and a curses pinentry fails. The backend's stdin is always `/dev/null`, so in an interactive call lendk gives the backend, never the target, a `GPG_TTY` naming stdin's terminal, else stderr's.
- In an interactive call, 85 is `decrypt` and 99 is `canceled`. Any other failure is `decrypt`, whose TEXT quotes gpg's last stderr line for the human to read.
- A change to GnuPG's status codes is caught by the suite, not at run time: it fails the real-GnuPG tests in `test/gpg.bats`, which run in both of pass's branches.
