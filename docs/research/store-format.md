# Audited formats for the lendk 2.0 store

Research for [#17][t17], a child of the wayfinder map [#15][t15]. It compares encrypted formats for a store that lendk owns: one machine, one store entry per key so git can sync the store by hand, and one recipient. It states facts and makes no decision; the grilling ticket [#22][t22] decides. Every source was read on 2026-10-19, and versions, dates and crate counts are as of that day.

age calls the public half of a key pair a *recipient* and the private half an *identity*. This document uses both words for every candidate.

## Summary

- age v1 has a C2SP specification and the CCTV test vectors. This research found no published third-party audit of the format, of the Go reference implementation, or of the Rust `age` crate and `rage`. Audits cover two primitive families under the `age` crate, ChaCha20-Poly1305 and the dalek curve crates. The crates behind its hardware recipient types, `p256`, `hpke` and `ml-kem`, each say they were never independently audited.
- rPGP, a Rust implementation of OpenPGP (RFC 9580), is the only candidate whose format implementation has published independent audits: 2019 and 2024-12.
- passage, gopass and sops are tools built on age or OpenPGP, not formats of their own. None has a published third-party audit that this research found.
- With age or OpenPGP, writing a store entry needs only the recipient, so a write needs no unlock. sops needs a file's data key to change a value inside an existing file. gopass checks its local identities before each write.
- In every one-file-per-key layout, the file name shows the key's name. The file size or the ciphertext shows the value's length: exactly for age and sops, and after optional compression for OpenPGP, the only format that defines padding. Only gopass's preview `cryptfs` backend hides names.
- Hardware unlock through the existing age plugins runs a plugin binary as a separate process: YubiKey (needs `pcscd` on Linux), Secure Enclave (macOS 14), TPM 2.0. All three can produce age's tagged recipients, which the `age` crate 0.12 encrypts to without the plugin.

## age v1

### Crypto and specification

- The specification is [c2sp.org/age][c2sp-age]. Each file has a random 128-bit file key that is never reused. A text header wraps the file key once per recipient stanza and ends with an HMAC-SHA-256 over the header, keyed through HKDF-SHA-256 from the file key. The payload is ChaCha20-Poly1305 in 64 KiB chunks, a STREAM construction, keyed through HKDF from the file key and a fresh 16-byte nonce ([spec, header and payload][c2sp-age]).
- Native recipient types ([spec][c2sp-age]):
  - X25519: an ephemeral X25519 share, HKDF-SHA-256 and ChaCha20-Poly1305 wrap the file key.
  - scrypt: a passphrase wraps the file key; the stanza carries its salt and the base-2 log of the work factor. An scrypt stanza must be the only stanza in a header, and an identity "SHOULD apply an upper limit to the work factor".
  - mlkem768x25519: a hybrid post-quantum type, HPKE with ML-KEM-768 and X25519.
  - p256tag and mlkem768p256tag: tagged types "designed for hardware keys", HPKE with P-256 ECDH, optionally hybrid with ML-KEM-768. The specification defines only the recipient encodings, "and does not define how the corresponding identities are generated or encoded". A tag lets the holder of the public key check whether a stanza is addressed to it, which "offers less privacy than the default recipient types". The p256tag tag includes a truncated hash of the recipient "for backwards compatibility with existing age-plugin-yubikey identities".
- The specification defines no padding. The ASCII armor is strict PEM ([spec, ASCII armor][c2sp-age]).
- Test vectors live in [C2SP/CCTV][cctv]. Go age 1.3.0 (2025-12-27) added the post-quantum and tagged types; 1.3.2 (2026-08-29) is the latest Go release ([1.3.0 notes][go-age-130], [releases][go-age-releases]).

### Audits

- This research found no published third-party audit of the age format, Go age, `rage` or the `age` crate. It searched the web, the issue trackers of [FiloSottile/age][go-age-issues-audit] and [str4d/rage][rage-issues-audit] for "audit", and both projects' advisory lists.
- One advisory, the same for both implementations: plugin names, recipients or identities could execute an arbitrary binary. It was published 2024-12-18 as [GHSA-32gq-x56h-299c][ghsa-go] (Go, fixed in 1.2.1) and [GHSA-4fg7-vxc8-qx5w][ghsa-rust] (Rust, fixed in `age` 0.11.1 with backports to 0.6.1 through 0.10.1).
- Audits of primitives the `age` crate uses:
  - NCC Group reviewed RustCrypto's AES-GCM and ChaCha20-Poly1305 for MobileCoin: engagement in December 2019, report published 2020-02-26, two consultants and five person-days ([NCC Group][ncc]). The crate's documentation reports "no significant findings" ([chacha20poly1305 docs][chacha-docs]).
  - Quarkslab audited `subtle` and `curve25519-dalek` for Tari Labs in mid-2019, and gave `x25519-dalek` and `ed25519-dalek` a "more marginal" look ([Quarkslab][quarkslab]).
  - Both audits read 2019 code. `age` 0.12.1 resolves `chacha20poly1305` 0.10.1, `curve25519-dalek` 4.1.3 and `x25519-dalek` 2.0.1 (the resolved tree under [Rust crates](#rust-crates)).
- The tagged and post-quantum types rest on crates that state no audit: `p256` says its arithmetic "has never been independently audited" ([p256 README][p256]); `ml-kem` says the same ([ml-kem README][mlkem]); `hpke` says "nobody has performed a paid audit", citing an internal Cloudflare review of version 0.8 ([hpke README][hpke]).
- Go's standard-library cryptography was audited by Trail of Bits (report 2025-03, announced 2025-05-19). The scope lists ECDH, ML-KEM, AES-GCM, SHA-2, SHA-3, HKDF, HMAC and the random number generator; it lists neither ChaCha20-Poly1305 nor scrypt ([Go blog][go-tob]). This bears on Go age and on Go plugins, not on a Rust lendk.

### Rust crates

- [`age`][crate-age] 0.12.1 (2026-07-14), MSRV 1.74, with one crates.io owner, str4d ([owners API][crate-age-owners]). Its manifest describes it as "[BETA]" with maintenance status "experimental" ([Cargo.toml][age-cargo]), and its changelog says "All versions prior to 1.0.0 are beta releases" ([changelog][age-changelog]). The repository keeps cargo-vet records in `supply-chain/` ([tree][rage-supply-chain]).
- Native types in 0.12.1 are X25519, scrypt, `tag` and `tagpq`, the last two encryption-only ([source][age-native], [changelog][age-changelog]). It has no native mlkem768x25519 type; issues [#621][rage-621] and [#598][rage-598] are open for it.
- Releases in 2025 and 2026 (0.11.2 to 0.12.1) fixed panics and parsing bugs in the plugin client, the armor code and the stream reader, and capped recipient and identity files at 16 MiB ([changelog][age-changelog]).
- `age::encrypted::EncryptedIdentity` wraps an identity file encrypted to a passphrase, and only that: it returns nothing for an identity file encrypted to any other recipient type ([source][age-encrypted]).
- The scrypt recipient picks a work factor that takes "around 1 second on this device" at encryption time ([source][age-scrypt]).
- Plugins (feature `plugin`): the crate finds `age-plugin-NAME` on `$PATH` through the `which` crate ([source][age-plugin-rs]). It starts the plugin in a temporary working directory with piped stdin and stdout, and with stderr discarded unless `AGEDEBUG=plugin`. It neither clears nor sets the plugin's environment, so the plugin inherits the caller's ([source][age-core-plugin-rs]).
- `rage` 0.12.1 is the command-line tool on the same crate. It decrypts passphrase-protected identity files automatically and asks for passphrases through `pinentry` when one is on `PATH` ([README][rage-readme]).
- Dependency weight, resolved with `cargo tree -e normal,build --target x86_64-unknown-linux-gnu` in a scratch crate, counting distinct packages with the crate itself ([method](#method)):
  - `age` 0.12.1 without optional features: 139. Its non-optional dependencies include a localization stack (`i18n-embed`, `i18n-embed-fl`, `rust-embed`, which pull in `fluent`), plus `hpke`, `ml-kem`, `p256` and `scrypt` ([Cargo.toml][age-cargo]).
  - `age` 0.12.1 with `plugin` and `armor`: 148. `plugin` adds `which`, `wsl`, `tempfile` and their dependencies.
  - Neither tree holds an HTTP, TLS or async runtime crate.

### Plugin protocol

- Specification: [c2sp.org/age-plugin][c2sp-plugin]. A plugin is a binary named `age-plugin-NAME` that the client finds on `PATH`, never relative to the working directory. Plugin recipients use the Bech32 prefix `age1NAME`, and plugin identities the prefix `AGE-PLUGIN-NAME-`.
- The client runs one of two state machines, `recipient-v1` to wrap file keys or `identity-v1` to unwrap them, over the plugin's stdin and stdout, framed as age stanzas. During a run the plugin can ask the client to show a message, ask for confirmation, or request a secret or PIN. The client may ignore a plugin failure during decryption and try another identity.
- `identity-v1` takes stanzas from several files in one run, so it "enables amortization of identity-specific costs (such as requesting a PIN or passphrase from the user) across multiple file decryptions" ([spec][c2sp-plugin]).
- The identity file of a plugin need not contain key material, only enough for the plugin to find it. The expected design for agents is a short-lived plugin that connects to, or starts, a long-lived agent daemon; agents are out of the specification's scope ([spec][c2sp-plugin]).

### Hardware plugins

- [age-plugin-yubikey][apy-readme] (Rust, str4d), 0.5.1 of 2026-04-08 ([crates.io][crate-apy]):
  - It uses PIV slots with ECDSA P-256 keys, and sets a PIN policy and a touch policy at generation. The private key stays in the YubiKey; the identity file holds what a client needs to find it.
  - On Linux and the BSDs the `pcscd` service must be installed and running.
  - It runs no agent. With PIN policy `once` it keeps the PIN cache across processes by not resetting the YubiKey, except on the YubiKey 4 series. Unplugging the key, using another applet or generating an identity ends that session ([README, agent support][apy-readme]).
  - Released 0.5.1 prints `age1yubikey` recipients. The unreleased main branch prints `age1tag` recipients ([changelog][apy-changelog]).
  - The in-process alternative is the [`yubikey`][crate-yubikey] crate, 0.8.0 of 2023-08-16 with 0.9.0 release candidates in 2026. It resolves to 75 packages on Linux, including `pcsc`.
- [age-plugin-se][ase-readme] (Swift, remko), 0.2.1 of 2025-12-27 ([releases][ase-releases]):
  - Generating an identity and decrypting need macOS 14 on a Mac with a Secure Enclave. Encrypting works on macOS 14, Linux or Windows without one.
  - Access control is chosen at generation: `none`, `passcode`, `any-biometry`, `any-biometry-and-passcode`, `any-biometry-or-passcode` (the default), `current-biometry` or `current-biometry-and-passcode`.
  - It can generate post-quantum keys (`--pq`). It prints `se` or `tag` recipients; `tag` recipients need no plugin to encrypt with age 1.3.0 or later.
  - Its README walks through a passage setup with Touch ID.
- [age-plugin-tpm][tpm-readme] (Go, Foxboron), 1.0.0 of 2025-12-27 and 1.0.1 of 2026-01-24. It creates keys on a TPM 2.0 and seals them outside it, supports a PIN, and prints `age1tag` recipients. For non-interactive use it reads the PIN from `AGE_TPM_PIN`, and its README warns that `/proc/PID/environ` exposes that variable.
- [age-plugin-fido2-hmac][fido2-readme] (Go) is experimental until 1.0.0. It wraps a software identity with the FIDO2 `hmac-secret` extension and moves that identity into memory to decrypt. [awesome-age][awesome-age] lists further plugins, such as TKey, FIDO2 PRF and Trezor.

### Passphrase-encrypted identities

- Go age and `rage` both decrypt an identity file that is itself an age file encrypted with a passphrase ([Go age docs][go-age-pkg], [rage README][rage-readme]). The `rage` README calls them "not necessary for most use cases, where access to the encrypted identity file implies access to the whole system".
- A passphrase-protected identity costs one scrypt run to unlock. Each store entry after that costs one X25519 operation, with no further key derivation ([spec][c2sp-age]). In lendk 1.x, gpg-agent caches the passphrase and every decrypt re-runs GnuPG's key derivation ([ADR 0007][adr7]).

## passage's tree

- [passage][passage-readme] is a fork of pass that calls the age or `rage` binary (`PASSAGE_AGE`) instead of GnuPG.
- Layout ([README][passage-readme], [script][passage-sh]):
  - The store sits at `~/.passage/store` (`PASSAGE_DIR`), and each store entry is `NAME.age`, written in binary age without armor.
  - The identities sit at `~/.passage/identities` (`PASSAGE_IDENTITIES_FILE`).
  - To encrypt, passage uses the nearest `.age-recipients` file, in the store entry's directory or the closest parent. Without one it encrypts with `-i` and the identities file, and age decrypts a passphrase-protected identities file first, which asks for the passphrase ([Go age docs][go-age-pkg]).
  - The script sets `umask 077` unless `PASSWORD_STORE_UMASK` overrides it.
- Git ([script][passage-sh]):
  - Each write commits with a message that names the store entry, such as "Add given password for NAME to store.".
  - `passage git init` writes `*.age diff=age` to `.gitattributes` and sets `diff.age.textconv` to `age -d -i` with the identities file, so `git diff` and `git log -p` decrypt both sides of a change.
- Maintenance: the last commit is of 2024-08-30, and the tags are `1.7.4a0` to `1.7.4a2` ([commits][passage-commits]). No audit was found.

## gopass

- [gopass][gopass-repo] is written in Go, and 1.17.4 is of 2026-10-10. Its crypto backends include GnuPG and age. Its docs call the age backend "experimental" with an "on-disk format likely to change" ([age backend][gopass-age]).
- Layout with age: each store entry is `NAME.age`, with recipients in `.age-recipients` ([source][gopass-age-go]). The identities sit in an encrypted keyring under the user configuration directory, at `age/identities`.
- Daemon: an agent caches the unlocked identities behind a socket at `$XDG_RUNTIME_DIR/gopass/gopass-age-agent.sock`. gopass starts it automatically unless `age.agent-enabled` is false. The docs say "Local processes running as the same user can use an unlocked agent" ([age backend][gopass-age]).
- Hardware: an age plugin can protect the keyring rather than each store entry. The docs report age-plugin-se tested on macOS, and YubiKey and TPM plugins "not tested" for this flow ([age backend][gopass-age]).
- Writes: `Encrypt` refuses unless one of the local identities is among the recipients. It reads the identities' recipients from a cache, or else loads the identities, which unlocks the keyring ([encrypt.go][gopass-encrypt], [identities.go][gopass-identities]).
- Git: each write commits with the message "Save secret: NAME", or "Save secret NAME: REASON" when a reason is given ([write.go][gopass-write]).
- Security model: gopass "does NOT protect the presence of the secrets OR the names of the secrets", and "Anyone with access to the git repository can see which secrets are stored" ([security.md][gopass-security]). The preview `cryptfs` backend hashes store entry names and keeps the name mapping in an age-encrypted table ([cryptfs][gopass-cryptfs]).
- The first line of a store entry is the password and the rest is the body ([secrets.md][gopass-secrets]).
- Audits: none from a third party was found. The 1.17.0 release notes list fixes "from code quality audit" with finding IDs, and the commits name no auditor and link no report ([1.17.0-rc.1 notes][gopass-rc1], [commit 49dddf75][gopass-cqa]).
- Rust: no crate reads gopass stores. Its age store entries are plain age files, which the `age` crate reads.

## sops

- [sops][sops-repo] is written in Go and has been a CNCF Sandbox project since 2023-05-17 ([CNCF][cncf-sops]); 3.13.3 is of 2026-07-23.
- Encryption protocol ([reference][sops-ref]):
  - Each file has a random 256-bit data key, wrapped once per master key (age, PGP or a cloud KMS).
  - Each leaf value is encrypted with AES-256-GCM under a random 256-bit IV, with the path of key names as additional data. Key names stay in cleartext: "We expect that keys do not carry sensitive information".
  - A MAC over all values, encrypted with the data key, sits at `sops.mac`.
  - Binary mode encrypts a whole file as one blob ([security][sops-security]).
- A value is stored as `ENC[AES256_GCM,data:...,iv:...,tag:...,type:...]`. An unchanged value keeps its IV, so its ciphertext stays the same across edits ([aes/cipher.go][sops-cipher]). Each encryption sets `lastmodified` to the current time and binds the MAC to it ([common.go][sops-common]). The metadata stores each age recipient in cleartext ([stores.go][sops-stores]).
- age support: recipients come from `--age` or `.sops.yaml`; identities come from `keys.txt`, `SOPS_AGE_KEY_FILE`, `SOPS_AGE_KEY` or `SOPS_AGE_KEY_CMD` ([age docs][sops-age]). 3.10.0 added age plugins and passphrase-protected age identities; 3.12.0 added hybrid post-quantum identities ([changelog][sops-changelog]).
- Threat model: "as strong as the weakest cryptographic mechanism"; it was written by the original Mozilla authors and kept "for historical reasons" ([security][sops-security]).
- Audits: none was found. Issue [#1125][sops-1125], "Would SOPS pass security auditing?", has been open since 2022. On 2026-08-14 the project published four advisories, one rated high, on Vault token exfiltration from untrusted files ([advisories][sops-advisories]).
- Rust: [`rops`][crate-rops] 0.1.7 (2026-02-14), MPL-2.0, one owner. It aims at "Full `sops` encrypted file compatibility" and supports YAML, JSON and TOML with age and AWS KMS ([goals][rops-goals]). Its default features pull the AWS SDK with `hyper`, `rustls` and `tokio`, for 272 packages on Linux. Without `aws-kms` it resolves to 171 packages, with `age` 0.11.5.

## OpenPGP (RFC 9580)

- [RFC 9580][rfc9580] (2024-07) defines v6 keys, the v2 SEIPD packet with AEAD, X25519 and X448, and recommends Argon2 for passphrase-derived keys. It defines a Padding packet "to defend against traffic analysis" in v2 SEIPD messages, and leaves its size to policy (section 5.14). A public-key encrypted session key packet names its recipient key unless it uses an "anonymous recipient" (section 5.1).
- Encrypting a message needs only the recipient's public key (section 5.1).
- lendk 1.x reads store entries that pass encrypts with GnuPG, under the GnuPG key ([glossary][glossary], [ADR 0007][adr7]).
- [rPGP][rpgp-security] (`pgp` 0.21.0, 2026-10-03, MSRV 1.88, one owner):
  - Audits: a 2019 assessment for the Open Tech Fund ([report][rpgp-2019]), with "No critical flaws"; a security analysis by ETH researchers (2024-03); and an evaluation by Radically Open Security for NLnet (2024-12), whose two advisories, CVE-2024-53856 and CVE-2024-53857, are fixed ([security status][rpgp-security]).
  - Known issue: its `rsa` dependency is vulnerable to the Marvin timing attack ([security status][rpgp-security]).
  - It decrypts GnuPG's OCB packets but does not implement the LibrePGP v5 format ([implementation status][rpgp-impl]).
  - Default features resolve to 150 packages on Linux, including `rsa`, `bzip2`, `flate2` and legacy ciphers such as `idea`, `cast5` and `blowfish`.
- [Sequoia][crate-sequoia] (`sequoia-openpgp` 2.4.2, 2026-10-14, LGPL-2.0-or-later, two owners). Its default backend is the Nettle C library: 123 Rust packages plus Nettle, built through `bindgen`. The RustCrypto backend needs the `allow-experimental-crypto` and `allow-variable-time-crypto` features and resolves to 199 packages. Its documentation says the RustCrypto crates "are not recommended for general use" ([crate docs][sequoia-docs]). No published third-party audit was found.
- Hardware: OpenPGP smart cards, with the Rust crate [`openpgp-card`][crate-openpgp-card] 0.7.0 (2026-07-23). This research did not survey them further.

## Comparison

Format and supply chain:

| Candidate | Specification | Crypto | Published audits | Rust crate | Packages on Linux |
| --- | --- | --- | --- | --- | --- |
| age v1 | C2SP age, CCTV vectors | X25519, scrypt, ML-KEM-768 hybrid, P-256 tagged; ChaCha20-Poly1305 STREAM payload | Format and implementations: none found. Primitives: ChaCha20-Poly1305 (NCC Group, 2020), dalek (Quarkslab, 2019). `p256`, `hpke`, `ml-kem`: none | `age` 0.12.1, beta, one owner | 139; 148 with `plugin` and `armor` |
| passage tree | the pass script, on age | as age | none found | none; `age` reads its store entries | as age |
| gopass | none for its layout; age or OpenPGP files | as age or OpenPGP | none found; an unnamed internal code-quality audit | none | not applicable |
| sops | the getsops.io protocol docs | AES-256-GCM per value, wrapped data key, MAC | none found | `rops` 0.1.7, one owner | 272 by default, with an HTTP and TLS stack; 171 without `aws-kms` |
| OpenPGP | RFC 9580 | v6 keys, AEAD, X25519, Argon2; optional padding | rPGP: 2019 and 2024-12. Sequoia: none found | `pgp` 0.21.0; `sequoia-openpgp` 2.4.2 | `pgp` 150; Sequoia 123 plus Nettle, or 199 with RustCrypto |

Store behavior, for one store entry per key:

| Candidate | Writing a store entry | File system shows | A rotation in git | Hardware |
| --- | --- | --- | --- | --- |
| age with passage's tree | Recipient only. passage needs the identity when no `.age-recipients` exists | `NAME.age`; value length plus a fixed overhead: 200 bytes for X25519, 252 for p256tag, 182 for scrypt; the recipient type; a 4-byte tag for tagged types | A binary file whose stanza, MAC and payload all change, even for the same value. Default diff: "Binary files differ". passage's textconv decrypts both sides. The commit message names the store entry | YubiKey, Secure Enclave, TPM and FIDO2 plugins, run as processes; tagged recipients encrypt without them |
| gopass, age backend | Checks local identities first: from a cache, or by unlocking the keyring | As passage. Names unprotected by design; `cryptfs` preview hashes them | A new age file, as with passage; message "Save secret: NAME" | age plugins; a plugin can protect the keyring; an agent daemon caches identities |
| sops, one file per key | A new file: recipients only. A changed value in an existing file: the file's data key | The file name; the key name in cleartext; the value length in the ciphertext; the age recipient; `lastmodified` | Only the changed value's line, the `mac` and `lastmodified` | age plugins since 3.10.0; PGP through GnuPG |
| OpenPGP in a pass-like tree | Recipient's public key only | `NAME.gpg`; the length after optional compression unless a Padding packet is added; the recipient key unless anonymous | The whole file changes | OpenPGP smart cards |

The overheads come from the specification's header grammar. The CCTV `x25519` and `scrypt` vectors measure 168-byte and 150-byte headers, and the payload adds a 16-byte nonce and a 16-byte tag for values under 64 KiB ([CCTV][cctv], [method](#method)). Go age 1.3.0's `age-inspect` prints the recipient types and the payload size of a file without decrypting it ([1.3.0 notes][go-age-130]).

## Facts that touch standing decisions and ADRs

- The standing decision asks for "a known, audited format". Among the formats here, only OpenPGP through rPGP has a published audit of the format implementation. The age format, Go age, the `age` crate and its tagged-type crates have none that this research found.
- "No network crate is compiled in": `rops` with default features pulls `hyper`, `rustls` and `tokio`. The `age`, `pgp` and Sequoia trees hold no HTTP, TLS or async runtime crate.
- ADR 0006 keeps the backend's environment to an allowlist. The `age` crate starts plugins with the caller's environment and finds them on `$PATH`. Its plugin constructors take a plugin name, not a path or an environment ([plugin.rs][age-plugin-rs-new], [age-core plugin.rs][age-core-plugin-rs]).
- ADR 0007 rules out a daemon. gopass's age backend runs an agent daemon; the plugin specification expects agents as daemons; age-plugin-yubikey runs none but needs the system's `pcscd` on Linux.
- Hardware unlock through an age plugin runs a separate process per call. The standing decision says lendk reads the store "in-process, with no separate backend". The specification leaves the identity side of the tagged types undefined, so each plugin defines it.

## Method

- Specifications, READMEs, changelogs and source files were read from each project's repository at the commits the links pin, through the GitHub API or `raw.githubusercontent.com`. Crate metadata came from the crates.io API.
- Package counts: a throwaway crate per candidate under a scratch directory, with its own `CARGO_HOME`, resolved with `cargo generate-lockfile` and listed with `cargo tree -q -e normal,build --target x86_64-unknown-linux-gnu --prefix none`. The count is the number of distinct `name version` lines, including the candidate crate. Nothing was built. Counts follow the newest compatible versions on 2026-10-19 and drift as dependencies release. deps.dev could not resolve `age` 0.12.1 ("elliptic_curve/^0.13: no candidates found"), so it was not used.
- Header sizes: the CCTV vectors were parsed up to the end of the `---` line. The p256tag size follows the specification's grammar: a 106-byte stanza line, a 44-byte body, the 22-byte version line and the 48-byte MAC line.
- Audit searches: Parallel and web search for each candidate with "audit", the issue trackers of FiloSottile/age, str4d/rage, gopasspw/gopass and getsops/sops, each project's advisory list, and OSTIF's CNCF audit pages. A "none found" above means these searches found none. It is not proof that none exists.

[t15]: https://github.com/v-bonilla/lendk/issues/15
[t17]: https://github.com/v-bonilla/lendk/issues/17
[t22]: https://github.com/v-bonilla/lendk/issues/22
[adr7]: ../adr/0007-no-daemon-no-value-cache.md
[glossary]: ../../GLOSSARY.md
[c2sp-age]: https://github.com/C2SP/C2SP/blob/e5746a0bcda86413310119abb2972e6f78c374fa/age.md
[c2sp-plugin]: https://github.com/C2SP/C2SP/blob/e5746a0bcda86413310119abb2972e6f78c374fa/age-plugin.md
[cctv]: https://github.com/C2SP/CCTV/tree/main/age/testdata
[go-age-130]: https://github.com/FiloSottile/age/releases/tag/v1.3.0
[go-age-releases]: https://github.com/FiloSottile/age/releases
[go-age-pkg]: https://pkg.go.dev/filippo.io/age
[go-age-issues-audit]: https://github.com/FiloSottile/age/issues?q=audit
[rage-issues-audit]: https://github.com/str4d/rage/issues?q=audit
[ghsa-go]: https://github.com/FiloSottile/age/security/advisories/GHSA-32gq-x56h-299c
[ghsa-rust]: https://github.com/str4d/rage/security/advisories/GHSA-4fg7-vxc8-qx5w
[ncc]: https://www.nccgroup.com/research/public-report-rustcrypto-aesgcm-and-chacha20pluspoly1305-implementation-review/
[chacha-docs]: https://docs.rs/crate/chacha20poly1305/0.10.0-pre/source/README.md
[quarkslab]: https://blog.quarkslab.com/security-audit-of-dalek-libraries.html
[p256]: https://github.com/RustCrypto/elliptic-curves/blob/master/p256/README.md
[mlkem]: https://github.com/RustCrypto/KEMs/blob/master/ml-kem/README.md
[hpke]: https://github.com/rozbb/rust-hpke/blob/main/README.md
[go-tob]: https://go.dev/blog/tob-crypto-audit
[crate-age]: https://crates.io/crates/age
[crate-age-owners]: https://crates.io/api/v1/crates/age/owners
[age-cargo]: https://github.com/str4d/rage/blob/v0.12.1/age/Cargo.toml
[age-changelog]: https://github.com/str4d/rage/blob/v0.12.1/age/CHANGELOG.md
[rage-supply-chain]: https://github.com/str4d/rage/tree/v0.12.1/supply-chain
[age-native]: https://github.com/str4d/rage/tree/v0.12.1/age/src/native
[rage-621]: https://github.com/str4d/rage/issues/621
[rage-598]: https://github.com/str4d/rage/issues/598
[age-encrypted]: https://github.com/str4d/rage/blob/v0.12.1/age/src/encrypted.rs#L18-L76
[age-scrypt]: https://github.com/str4d/rage/blob/v0.12.1/age/src/native/scrypt.rs#L33-L36
[age-plugin-rs]: https://github.com/str4d/rage/blob/v0.12.1/age/src/plugin.rs#L230-L250
[age-plugin-rs-new]: https://github.com/str4d/rage/blob/v0.12.1/age/src/plugin.rs#L386-L396
[age-core-plugin-rs]: https://github.com/str4d/rage/blob/v0.12.1/age-core/src/plugin.rs#L70-L99
[rage-readme]: https://github.com/str4d/rage/blob/v0.12.1/README.md
[apy-readme]: https://github.com/str4d/age-plugin-yubikey/blob/cafbc75fbd309e6f7ab62749052f98a91a89764e/README.md
[apy-changelog]: https://github.com/str4d/age-plugin-yubikey/blob/cafbc75fbd309e6f7ab62749052f98a91a89764e/CHANGELOG.md
[crate-apy]: https://crates.io/crates/age-plugin-yubikey
[crate-yubikey]: https://crates.io/crates/yubikey
[ase-readme]: https://github.com/remko/age-plugin-se/blob/57ccea12fc1a3d3bb81b8866745be4d2951c4eaf/README.md
[ase-releases]: https://github.com/remko/age-plugin-se/releases
[tpm-readme]: https://github.com/Foxboron/age-plugin-tpm
[fido2-readme]: https://github.com/olastor/age-plugin-fido2-hmac
[awesome-age]: https://github.com/FiloSottile/awesome-age
[passage-readme]: https://github.com/FiloSottile/passage/blob/4e4c5ae14be91833791d45608f50868175c1490f/README
[passage-sh]: https://github.com/FiloSottile/passage/blob/4e4c5ae14be91833791d45608f50868175c1490f/src/password-store.sh
[passage-commits]: https://github.com/FiloSottile/passage/commits/main
[gopass-repo]: https://github.com/gopasspw/gopass
[gopass-age]: https://github.com/gopasspw/gopass/blob/32231f6de531975874bd33bbf77f12881166258a/docs/backends/age.md
[gopass-age-go]: https://github.com/gopasspw/gopass/blob/32231f6de531975874bd33bbf77f12881166258a/internal/backend/crypto/age/age.go#L24-L28
[gopass-encrypt]: https://github.com/gopasspw/gopass/blob/32231f6de531975874bd33bbf77f12881166258a/internal/backend/crypto/age/encrypt.go#L23-L47
[gopass-identities]: https://github.com/gopasspw/gopass/blob/32231f6de531975874bd33bbf77f12881166258a/internal/backend/crypto/age/identities.go#L146-L171
[gopass-write]: https://github.com/gopasspw/gopass/blob/32231f6de531975874bd33bbf77f12881166258a/internal/store/leaf/write.go#L80-L86
[gopass-security]: https://github.com/gopasspw/gopass/blob/32231f6de531975874bd33bbf77f12881166258a/docs/security.md
[gopass-cryptfs]: https://github.com/gopasspw/gopass/blob/32231f6de531975874bd33bbf77f12881166258a/docs/backends/cryptfs.md
[gopass-secrets]: https://github.com/gopasspw/gopass/blob/32231f6de531975874bd33bbf77f12881166258a/docs/secrets.md
[gopass-rc1]: https://github.com/gopasspw/gopass/releases/tag/v1.17.0-rc.1
[gopass-cqa]: https://github.com/gopasspw/gopass/commit/49dddf75
[sops-repo]: https://github.com/getsops/sops
[cncf-sops]: https://www.cncf.io/projects/sops
[sops-ref]: https://github.com/getsops/docs/blob/3aa2b6983295372e1b569b43929fe6828c54e912/content/en/docs/reference/_index.md#encryption-protocol
[sops-security]: https://github.com/getsops/docs/blob/3aa2b6983295372e1b569b43929fe6828c54e912/content/en/docs/security/_index.md
[sops-age]: https://github.com/getsops/docs/blob/3aa2b6983295372e1b569b43929fe6828c54e912/content/en/docs/usage/identities/age/_index.md
[sops-cipher]: https://github.com/getsops/sops/blob/dead54fb42be02c1d29a16b8e8367f7388d66205/aes/cipher.go#L140-L200
[sops-common]: https://github.com/getsops/sops/blob/dead54fb42be02c1d29a16b8e8367f7388d66205/cmd/sops/common/common.go
[sops-stores]: https://github.com/getsops/sops/blob/dead54fb42be02c1d29a16b8e8367f7388d66205/stores/stores.go#L40-L110
[sops-changelog]: https://github.com/getsops/sops/blob/dead54fb42be02c1d29a16b8e8367f7388d66205/CHANGELOG.md
[sops-1125]: https://github.com/getsops/sops/issues/1125
[sops-advisories]: https://github.com/getsops/sops/security/advisories
[crate-rops]: https://crates.io/crates/rops
[rops-goals]: https://github.com/gibbz00/rops/blob/main/book/goals.md
[rfc9580]: https://www.rfc-editor.org/rfc/rfc9580.html
[rpgp-security]: https://github.com/rpgp/rpgp/blob/main/docs/SECURITY_STATUS.md
[rpgp-impl]: https://github.com/rpgp/rpgp/blob/main/docs/IMPL_STATUS.md
[rpgp-2019]: https://delta.chat/assets/blog/2019-first-security-review.pdf
[crate-sequoia]: https://crates.io/crates/sequoia-openpgp
[sequoia-docs]: https://docs.rs/crate/sequoia-openpgp/latest
[crate-openpgp-card]: https://crates.io/crates/openpgp-card
