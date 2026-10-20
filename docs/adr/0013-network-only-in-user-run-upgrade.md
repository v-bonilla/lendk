# Only a `lendk upgrade` the human runs uses the network

lendk reads every mapped key, so any network use by it is a path for values to leave the machine, which a reviewer has to rule out. lendk sends no telemetry, checks for no update and never updates itself. It uses the network only in `lendk upgrade`, only when the human runs it, and only through the download tool it starts for the release's two assets. The source names `curl` and `wget` only in the one function that downloads, between the `# lint: network begin` and `# lint: network end` markers, and never `nc` or `/dev/tcp`. Reviewing lendk's network use is then reviewing one function.

## Considered Options

- Telemetry: a channel out of the one process that holds every value.
- A version check or update notice in `check`, `run` or the shims: a network call on the path every mapped command takes, which slows each shim and tells a server each time one runs. `lendk check` reports drift locally instead: stale or stray shims, a shadowed command, a shim directory missing from PATH, a GnuPG below 2.4.
- Updating itself: it would replace the file that reads every key without the human deciding. An agent never upgrades lendk unasked either ([ADR 0012](0012-agent-fixes-never-widen-access.md)).
- bash's `/dev/tcp` or `nc`: raw connections without TLS, which a search for `curl` and `wget` would miss.

## Consequences

- `test/lint-repo.bash` and `test/net.bats` hold the region: one begin and one end marker, no download tool named outside it, and no `nc` or `/dev/tcp`. Under strace, every other verb, and `lendk upgrade` from a `file://` base, connects to no internet address.
- In the Rust source, `clippy.toml`'s `disallowed-types` bans the socket types of `std::net` and `std::os::unix::net`, `make lint` fails on any use, and `test/lint-repo.bash` allows `curl` and `wget` only between the `// lint: network begin` and `// lint: network end` markers. No crate ban reaches `std::net`, so `test/net.bats` stays the behavior check ([ADR 0016](0016-dependencies-admitted-by-rule.md)).
- The download tool runs with PATH without the shim directory and stdin `/dev/null`, and its output never reaches the caller, so a mapped `curl` runs without its shim and gets no key.
- What `lendk upgrade` trusts when it does use the network: see [ADR 0014](0014-upgrade-trusts-https-release-replaces-one-file.md).
