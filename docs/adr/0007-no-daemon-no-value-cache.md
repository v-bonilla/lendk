# No daemon and no value cache: gpg-agent's passphrase cache is the only cache

Each call decrypts the keys it needs, and decrypts cost time: gpg-agent caches the passphrase, not the unlocked GnuPG key, so every decrypt re-runs the key derivation, which with GnuPG's default work factor can approach one second per key on slow machines. lendk still runs no daemon and keeps no cache of values. It relies on gpg-agent's passphrase cache, whose lifetime (`default-cache-ttl`, `max-cache-ttl`) and flushing (`gpgconf --reload gpg-agent`) stay the human's, and it never changes GnuPG settings. Values kept beyond a call, in a process or a file, would be plaintext within reach of every same-user process, held by something that outlives the calls lendk bounds.

## Considered Options

- A lendk daemon holding decrypted values: a long-lived process with every value in memory, which other same-user processes can query or read.
- A cache file of values: values never touch a file ([ADR 0006](0006-values-only-in-memory.md)).
- lendk tuning GnuPG for speed: `s2k-count 8388608` in `gpg-agent.conf`, then `gpg --passwd`, cuts a decrypt to tens of milliseconds, but makes passphrase guessing about 20 times cheaper for anyone holding the GnuPG key's file. That trade-off belongs to the human, and only with a strong passphrase, so the README documents it and lendk applies nothing.

## Consequences

- `lendk run` makes one backend read per key the caller does not already hold, so a nested shim under a mapped command reuses its caller's values without a decrypt.
- lendk writes no cache and no log.
