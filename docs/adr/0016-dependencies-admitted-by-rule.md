# Dependencies admitted by rule, held by cargo-deny and cargo-vet

lendk depends on the standard library first. A crate joins only for what lendk must not or cannot write itself: the store format and its crypto (`age` and `age-core`), OS calls the standard library lacks (`libc`, and on macOS `security-framework-sys` and `core-foundation-sys`), and zeroing (`zeroize`). `deny.toml` names every crate the tree resolves to, and `supply-chain/` records who reviewed each one or exempts it. `make check` checks both offline, so a new crate name, a new version, a changed build script or a network crate fails until a reviewed commit admits it. The reasons:

- An audit of lendk reads its own source, `Cargo.lock`, `deny.toml` and `supply-chain/`. A Rust binary rests on a tree of about 140 crates, so the audit controls what enters that tree.
- cargo-vet's imported audits cover a fifth of the first tree. The rest started as exemptions, once, and the list only shrinks: every later crate or version is audited, through an import or by the maintainer, in the commit that brings it. Most of the first tree is exempt, not reviewed. `age` and `age-core`, which parse every store entry, are never exempt.
- No crate ban reaches `std::net`. clippy's `disallowed-types` covers lendk's own code, and `test/net.bats` covers its behavior ([ADR 0013](0013-network-only-in-user-run-upgrade.md)).
- One pinned toolchain builds, tests and releases lendk, and Linux releases rebuild bit-for-bit from their tag.

## Considered Options

- A deny list of known names alone: it misses a crate of any other name.
- cargo-crev: a web of trust that none of rage, ripgrep or uv runs.
- `cargo auditable`: a third-party wrapper in the release build, while the tag's `Cargo.lock` already records what shipped.
- Convenience crates such as `clap`, `anyhow` and `serde`: the frozen interface is byte-exact text, and each adds crates to audit.
- Wrapper crates over OS calls, such as `rustix`, `nix`, `linux-keyutils` and `security-framework`: `rustix` hides exec, and `security-framework` compiles a TLS wrapper.
- Each distro's `rustc`: Debian 13, Ubuntu 24.04 and Fedora ship 1.85, 1.75 and 1.99, and each would need its own test run.

## Consequences

- `make check` runs `cargo deny --frozen check -D warnings bans licenses sources` (with `-D warnings`, since a build script that misses its SHA-256 pin is otherwise only a warning), `cargo vet --locked --frozen`, clippy at `-D warnings` and `cargo test`. CI checks RustSec advisories on each push and daily, against `dev`'s lockfile and the latest release tag's.
- An update is targeted, one `cargo update -p` per need, with its audits. Only the maintainer certifies an audit.
- Copies of plaintext inside `age` and `scrypt` are zeroed on drop, except scrypt's work memory, and none is kept out of swap. The security model says so.
