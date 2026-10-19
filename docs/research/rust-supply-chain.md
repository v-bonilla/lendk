# Crate, build and release practices for a Rust lendk

Research for [#19](https://github.com/v-bonilla/lendk/issues/19), a ticket of the wayfinder map [#15](https://github.com/v-bonilla/lendk/issues/15). It surveys what can stand in for the one-file audit of [ADR 0010](../adr/0010-one-bash44-file-posix-utils.md) once lendk is a Rust binary, and what [ADR 0013](../adr/0013-network-only-in-user-run-upgrade.md) and [ADR 0014](../adr/0014-upgrade-trusts-https-release-replaces-one-file.md) meet in a Rust release. The sources are tool documentation, compiler and linker source, the workflow files of rage, ripgrep and uv at pinned commits, their published release assets, and GitHub Actions run data, all read on 2026-10-19. It states facts and decides nothing: [#27](https://github.com/v-bonilla/lendk/issues/27) and [#28](https://github.com/v-bonilla/lendk/issues/28) decide.

## Summary

- Four tools cover the dependency part of an audit. cargo-deny fails CI on banned crates, unknown sources, advisories and build-time binaries. cargo-vet records who reviewed each crate version. cargo-crev is a web of trust of signed reviews. cargo-auditable embeds the dependency list in the binary, so scanners can read it later.
- cargo-deny bans a named crate anywhere in the graph, or, with a non-empty `allow` list, every crate not listed. No crate ban reaches `std::net`, which is part of the standard library. clippy's `disallowed-types` lint covers lendk's own code only, and the strace test of ADR 0013 covers behavior.
- Rust binaries reproduce when the toolchain, the build paths and the host OS match. Without remapping, the build machine's Cargo home path ends up in the binary. Cargo stabilized `profile.trim-paths` on 2026-10-06, with no default, and the stable Cargo book lists it as unstable on 2026-10-19.
- Both musl targets link statically by default, and both have Tier 2 support with musl 1.2.5. `aarch64-apple-darwin` is Tier 1, `x86_64-apple-darwin` Tier 2.
- rage and ripgrep ship macOS binaries that carry only the signature the linker adds. uv signs with a Developer ID and notarizes. On Apple silicon an ad-hoc signature is enough to run. curl and tar set no quarantine, and Apple DTS says Gatekeeper usually assesses only quarantined code.
- ripgrep and uv publish a `.sha256` file per asset; rage publishes no checksum. All three attest build provenance through GitHub. Only uv ships an install script, generated per release with the checksums inside it.
- In ripgrep's and rage's release runs, a musl or macOS build job took between 1 and 5 minutes. Standard runners cost nothing in a public repository.

## What replaces the one-file audit

ADR 0010 rests the audit on reading one file. A Rust lendk adds `Cargo.lock`, every crate it pins, code that runs at build time, and the toolchain.

### cargo-deny

cargo-deny 0.20.2 was released on 2026-07-09 ([release][deny-release]). Its checks, as its configuration reference documents them:

- **advisories**: the RustSec Advisory Database, cloned or fetched from GitHub on each run. Vulnerability and notice advisories always fail. Unmaintained crates fail by default (`all`), unsound ones only when a workspace crate depends on them directly (`workspace`), and yanked versions warn. `--offline` or `check --disable-fetch` skips the fetch, and `maximum-db-staleness` (default 90 days) then bounds the database's age ([advisories][deny-adv]).
- **bans**: `deny` lists banned crates, each with an optional `reason`, `use-instead` and `wrappers`, the crates allowed to depend on it directly. `allow`, when non-empty, denies every crate it does not list. `[[bans.features]]` denies or allows features per crate, with `exact` to require an exact match. `multiple-versions` and `wildcards` default to `warn` ([bans][deny-bans]). The documented use case is a crate removed once that must not come back through a `cargo update` or a default feature ([bans overview][deny-bans-overview]).
- **bans.build**: scans crates that run at compile time. `executables` (native ELF, PE or Mach-O files in such a crate) defaults to `deny`, and `interpreted` (shebang scripts) to `allow`. `allow-build-scripts` lists the crates allowed a build script: omitted, all are allowed; empty, none are. `include-dependencies` defaults to `false`. `[[bans.build.bypass]]` exempts a build script by its SHA-256 ([bans][deny-bans]).
- **sources**: `unknown-registry` and `unknown-git` default to `warn`, and `allow-registry` defaults to the crates.io index. Set to `deny`, any other source fails ([sources][deny-sources]).
- **graph**: by default every crate Cargo resolves counts, target-specific and dev-dependencies included. `targets` narrows the platforms, `exclude-dev` drops dev-dependencies, and `all-features` resolves with every feature on ([config][deny-cfg]).

EmbarkStudios publishes a GitHub action for it, `cargo-deny-action` 2.1.1 ([release][deny-action]).

### cargo-vet

cargo-vet is Mozilla's tool to "ensure that third-party Rust dependencies have been audited by a trusted entity" ([book][vet]). Its latest crates.io version is 0.10.2, from 2026-01-13 ([crate][vet-crate]).

- **Criteria**: `safe-to-run` means a crate can be compiled, run and tested without surprising consequences, among them "Connecting to untrusted network endpoints". `safe-to-deploy` asks the auditor to "review enough to fully reason about the behavior of all unsafe blocks and usage of powerful imports", covers build dependencies and procedural macros through the code they generate, and implies `safe-to-run` ([criteria][vet-criteria]).
- **Imports**: `config.toml` names other projects' `audits.toml` by URL. `cargo vet` fetches them and records them in `imports.lock`; `--locked` skips that fetch ([imports][vet-import]). The CI recipe runs `cargo vet --locked` ([CI][vet-ci]).
- **Trusted publishers**: a `[[trusted]]` entry trusts a crate's releases by one publisher, between a start and an end date. The book calls it a heuristic: "The trusted publisher is not consulted and may or may not have personally authored or reviewed all the code" ([trusted][vet-trusted]).
- **Gaps**: dependencies without an audit go on an exemption list, which shrinks over time ([book][vet]).

rage runs `cargo vet --locked` on every push and pull request ([audits.yml][rage-audits]). Its `supply-chain/config.toml` imports seven audit sets (Bytecode Alliance, Embark Studios, Fermyon, Google, ISRG, Mozilla, Zcash) and holds 273 exemptions ([config][rage-vet]). Its `audits.toml` holds one audit of its own and 15 trusted-publisher entries ([audits][rage-vet-audits]), its `imports.lock` 320 imported audits ([imports][rage-vet-imports]), and its `Cargo.lock` 386 packages ([lockfile][rage-lock]). rage also runs `cargo audit` daily ([audit.yml][rage-audit]).

### cargo-crev

cargo-crev is "a cryptographically verifiable code review system for the cargo (Rust) package manager", and calls itself "a work in progress, but it should be usable at all times" ([README][crev]). Its latest release is 0.27.1, from 2026-04-12 ([release][crev-release]).

- Reviews are YAML proofs signed with the key `cargo crev id new` generates, kept in public git repositories, customarily named `crev-proofs` ([getting started][crev-start]).
- "Trust in crev is transitive": trusting user b, who trusts user c, implies trust in c, at a level no higher than b's ([getting started][crev-start]).
- `cargo crev verify` reports per crate `pass` (reviewed by enough trusted peers), `none`, `flagged` or `dangerous` ([getting started][crev-start]).

None of rage, ripgrep or uv runs cargo-crev in the workflows read here.

### cargo-auditable

cargo-auditable 0.7.7 was released on 2026-10-02 ([release][auditable-release]). From its README ([README][auditable]):

- `cargo auditable build --release` embeds the dependency tree as Zlib-compressed JSON in a linker section named `.dep-v0`. It "uses under 4kB even on large dependency trees with 400+ entries".
- The format is "specifically designed not to disrupt reproducible builds": no timestamps, and sorted JSON.
- `cargo audit bin`, trivy, grype and osv-scanner scan such binaries; syft and others recover the list.
- Alpine, NixOS, openSUSE, Void, Chimera and Wolfi build with it, and Ubuntu 26.04 for select packages.
- Its Cargo RFC (rust-lang/rfcs#2801) waits on the SBOM RFC (#3553), which Cargo implements as the unstable `-Z sbom` ([unstable][cargo-unstable]).

None of the three release workflows read here builds with it.

### Code that runs at build time

Cargo compiles a crate's `build.rs` and runs it before building the crate, and it "may perform any number of tasks". Writing only under `OUT_DIR` is guidance, not enforced ([build scripts][cargo-build-scripts]). cargo-deny's `bans.build` limits which crates may have one, and cargo-vet's criteria cover what build-time code does.

### Locked and offline builds

- `--locked` fails when `Cargo.lock` is missing or would change. `--offline` stops Cargo from using the network, and `--frozen` is both ([cargo build][cargo-build]).
- `cargo vendor` copies every crates.io and git dependency into a directory and prints the source replacement that makes Cargo use it ([cargo vendor][cargo-vendor]).
- Rust "references build dependencies through cryptographic hashes recorded in dependency lockfiles", and Arch Linux, Alpine and Homebrew rely on the upstream project to commit `Cargo.lock` ([reproducible-builds.org][rb-rust]).

## Keeping network crates out (ADR 0013)

ADR 0013 lets lendk use the network only in a `lendk upgrade` the human runs, through curl or wget. The standing decision keeps that subprocess and compiles in no network crate.

- A `[bans] deny` entry fails the check when the named crate appears anywhere in the graph, unless the path to it runs through one of its `wrappers` ([bans][deny-bans]). The entry shape for the crates the ticket names:

  ```toml
  [bans]
  deny = [
    { crate = "reqwest", reason = "ADR 0013" },
    { crate = "hyper", reason = "ADR 0013" },
    { crate = "ureq", reason = "ADR 0013" },
    { crate = "tokio", reason = "ADR 0013" },
  ]
  ```

- A deny list catches only the names it lists. A non-empty `[bans] allow` list denies every crate not on it, so a crate of any name fails until someone adds it ([bans][deny-bans]).
- `[[bans.features]]` denies a feature of an allowed crate, such as an optional HTTP client ([bans][deny-bans]). With `[graph] all-features = true`, optional dependencies behind features count too ([config][deny-cfg]).
- `std::net` is part of the standard library, not a crate, so no crate ban removes it. clippy's `disallowed-types` lint takes paths such as `std::net::TcpListener` from `clippy.toml`; it is warn-by-default and fires only when configured ([clippy source][clippy-disallowed]). Cargo passes `--cap-lints allow` when it compiles dependencies ([rustc lints][rustc-lints]), so such a lint checks lendk's own crates only.
- Inside dependencies, cargo-vet's `safe-to-deploy` review covers "powerful imports" ([criteria][vet-criteria]).
- Behavior stays testable black-box: `test/net.bats` runs every verb under strace and fails on any `AF_INET` or `AF_INET6` connect, whatever language lendk is written in.

## Reproducible builds

### What rustc and Cargo give

- "It is very uncommon for Rust programs to record the date and time the binary has been compiled", and "Programs written in Rust are often already reproducible by default, given the original build toolchain is version-matched and build paths are normalized". A build that needs the time should read `SOURCE_DATE_EPOCH` first ([reproducible-builds.org][rb-rust]). `git log -1 --pretty=%ct` gives it from git ([SOURCE_DATE_EPOCH][rb-sde]).
- To find a difference, build twice, move `target` between builds, and run diffoscope on both ([reproducible-builds.org][rb-rust]).
- A toolchain pin is a `rust-toolchain.toml`; rage's pins `channel = "1.85.0"` ([rage][rage-toolchain]).

### Build paths

- `--remap-path-prefix FROM=TO` rewrites path prefixes in compiler output "as a best effort"; with several matches the last one wins ([rustc remap][rustc-remap], [rustc arguments][rustc-args]).
- `--remap-path-scope` picks `macro` (panic messages), `diagnostics`, `debuginfo`, `coverage`, `object` or `all`. The page says: "If your goal is reproducible builds (including metadata) use the `all` scope" ([rustc remap][rustc-remap]). It is stable since Rust 1.95 ([Cargo PR 17488][trim-paths-pr]).
- On Apple platforms the linker writes OSO entries that rustc does not remap; they need the linker's `-oso_prefix` ([rustc remap][rustc-remap]).
- Cargo's `profile.trim-paths` (`"none"`, `"object"`, `"all"`) passes those flags for the whole graph: registry crates become `/cargo/registry/<id>/...`, the standard library `/rustc/<commit>/...`, and package paths relative ([unstable][cargo-unstable]). Cargo stabilized it on 2026-10-06 ([PR 17488][trim-paths-pr], [tracking issue][trim-paths-issue]). The stabilization sets no default for the release profile, and calls the feature best-effort ([PR 17488][trim-paths-pr]). The stable Cargo book still lists it as unstable on 2026-10-19 ([unstable][cargo-unstable]).
- What the published binaries hold, counted with `grep -a -o` on the release assets:
  - ripgrep 15.2.0 `aarch64-apple-darwin`: 110 occurrences of the macOS runner's home directory followed by `.cargo/registry/src/index.crates.io-1949...` ([release][rg-15.2.0]).
  - rage 0.12.1 `arm64-darwin`: 240 such occurrences, plus 108 of `/rustc/<commit>` ([release][rage-0.12.1]).
  - uv 0.13.1 `aarch64-apple-darwin`: 1179 such occurrences ([release][uv-0.13.1]).
  - ripgrep 15.2.0 `x86_64-unknown-linux-musl`, built in a `cross` Docker image: 112 occurrences of `/cargo/registry/src/...` and 71 of `/rustc/<commit>`, and no home directory ([release][rg-15.2.0], [workflow][rg-release-cross]).
- The path a dependency's panic location records thus follows `CARGO_HOME`, and the standard library's paths come pre-remapped to `/rustc/<commit>`.

### Host OS

Cargo issue 8140 is open and labelled `S-needs-design`: the `-C metadata` hash Cargo passes to rustc differs with the compiling OS, so the same target built on Linux and on macOS differs, even with a pinned toolchain and remapped paths ([cargo#8140][cargo-8140]).

### Static musl

- `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl` are Tier 2 with host tools, on musl 1.2.5. `aarch64-apple-darwin` is Tier 1 for macOS 11 and later; `x86_64-apple-darwin` is Tier 2 for macOS 10.12 and later ([platform support][rustc-platforms]).
- Both musl target specs set `crt_static_default = true` under a `FIXME(compiler-team#422)` that says musl targets should link dynamically by default ([x86_64][spec-x86-musl], [aarch64][spec-arm-musl]). That proposal closed on 2021-05-20 ([compiler-team#422][mcp-422]), and the default has not changed. The Rust Reference lists `x86_64-unknown-linux-musl` among the static-by-default targets but not the aarch64 one ([linkage][ref-linkage]).
- ripgrep pins `-C target-feature=+crt-static` and `-C link-self-contained=yes` for `x86_64-unknown-linux-musl` in `.cargo/config.toml`. Its comment reads: "The whole point of MUSL with respect to ripgrep is to create a fully statically linked executable" ([config][rg-config]).
- ripgrep's published `x86_64` musl `rg` is a static-pie ELF, and its `aarch64` musl `rg` a static ELF (`file` on the release assets).
- ripgrep builds aarch64 musl on x86_64 runners through `cross` 0.2.5 and its Docker images ([workflow][rg-release-cross]). rage cross-links its musl Debian packages with `gcc-aarch64-linux-gnu` and `musl-tools` ([workflow][rage-release-deb]). GitHub also offers native arm64 Linux runners, `ubuntu-24.04-arm` among them ([runners][gh-runners]).

### Archives

- A reproducible tar uses `--sort=name`, `--mtime="@${SOURCE_DATE_EPOCH}"`, `--owner=0 --group=0 --numeric-owner`, and a `--pax-option` that drops atime and ctime ([archives][rb-archives]).
- The same page recommends `git archive --format=tar TAG | gzip -6 -n` because git's internal gzip "is not" stable. lendk's `make dist` uses `git archive --format=tar.gz`, the internal gzip.

### Evidence and its limits

- Debian's reproducible-builds CI reports `rust-ripgrep` 14.1.1-1 in trixie on amd64 as reproducible, tested on 2025-07-31 ([Debian][rb-debian-rg]). That is Debian's own glibc build, not ripgrep's release asset.
- None of the release workflows read here rebuilds and compares its output.

## How rage, ripgrep and uv release

| | ripgrep 15.2.0 | rage 0.12.1 | uv 0.13.1 |
| --- | --- | --- | --- |
| Trigger | tag push; draft release ([workflow][rg-release-draft]) | tag push; uploads as a prerelease ([workflow][rage-release-upload]) | manual dispatch behind a `release-gate` environment that "requires a 2-factor approval" ([workflow][uv-release-gate]) |
| Linux archives | static musl for x86_64, aarch64 and armv7, plus glibc for aarch64, armv7 and s390x ([assets][rg-15.2.0]) | glibc for x86_64, arm64 and armv7, built on `ubuntu-22.04`; musl only in Debian packages ([workflow][rage-release]) | glibc and musl for x86_64, aarch64, armv7, i686 and riscv64gc ([assets][uv-0.13.1]) |
| macOS builds | both targets on `macos-latest`, which is arm64 ([workflow][rg-release-macos]) | arm64 on `macos-latest`, x86_64 on `macos-15-intel` ([workflow][rage-release-macos]) | `namespace-profile-macos-15` runners, linked with `rust-lld` ([workflow][uv-build-macos]) |
| `--locked` | no ([workflow][rg-release-build]) | yes ([workflow][rage-release-build]) | yes ([workflow][uv-build-macos]) |
| Checksums | one `.sha256` per asset, from `shasum -a 256` ([workflow][rg-release-sum]) | none ([assets][rage-0.12.1]) | one `.sha256` per asset and a combined `sha256.sum` ([assets][uv-0.13.1]) |
| Install script | none; the README points to the archives and package managers ([README][rg-readme]) | none; the README lists package managers ([README][rage-readme]) | `uv-installer.sh`, a release asset ([assets][uv-0.13.1]) |
| Provenance | `actions/attest-build-provenance` on each archive ([workflow][rg-release-attest]) | `actions/attest-build-provenance` on the binaries ([workflow][rage-release-attest]) | `actions/attest-build-provenance` on every asset ([workflow][uv-release-attest]) |
| macOS signature | linker ad-hoc on arm64, none on x86_64 (see below) | linker ad-hoc on arm64, none on x86_64 | Developer ID with the hardened runtime, notarized ([workflow][uv-sign]) |
| Dependency gate | the release checklist runs `cargo update` and reviews the updates ([checklist][rg-checklist]) | `cargo vet --locked` on each push, `cargo audit` daily | a crates.io publishing policy check ([workflow][uv-policies]) |

ripgrep builds its x86_64 musl, macOS and Windows binaries with a nightly toolchain, and the rest with stable ([workflow][rg-release-matrix]). It strips the macOS binary with `strip` after linking ([workflow][rg-release-strip]).

### uv's installer

uv's `dist-workspace.toml` names `cargo-dist-version = "0.32.0"`, `installers = ["shell", "powershell"]` and `github-attestations = true` ([config][uv-dist]). The header of its release workflow says cargo-dist generated it and the team maintains it by hand ([workflow][uv-release]). dist itself is at 0.33.0, from 2026-09-11 ([release][dist-release]). The generated `uv-installer.sh` of 0.13.1 ([asset][uv-installer]):

- names one version, `APP_VERSION="0.13.1"`, and the SHA-256 of every archive inside the script, so the installer of a release checks the archives of that release;
- verifies with `sha256sum`, and when `sha256sum` is missing prints that it is skipping verification and goes on;
- picks the target from `uname -s` and `uname -m`, takes musl when `ldd --version` mentions musl, takes the glibc archive when glibc is at least 2.17 and the static musl one otherwise, and reads `sysctl hw.optional.arm64` on macOS because "Darwin `uname -m` can lie due to Rosetta";
- downloads with curl or wget.

uv's docs install it with `curl -LsSf https://astral.sh/uv/install.sh | sh`, or a pinned `https://astral.sh/uv/0.13.1/install.sh` ([docs][uv-install-doc]). dist's own docs say a checksum fetched over HTTPS without a signature adds little security but still catches corruption ([checksums][dist-checksums]), the same limit ADR 0014 states for `SHA256SUMS`.

## macOS: signing, Gatekeeper and quarantine

### Apple silicon needs a signature, and the linker adds one

- From the macOS Big Sur release notes: on Apple silicon "the operating system enforces that any executable must be signed before it's allowed to run", and "a simple ad-hoc signature is sufficient". The policy does not apply to x86_64 binaries under Rosetta 2 or on Intel Macs ([Big Sur notes][apple-bigsur]).
- The same notes: `clang` and `ld` sign at link time, and a tool that changes the binary after linking, such as `strip` or `install_name_tool`, may need a `codesign` call afterwards. These signatures verify on any machine, but "binaries signed this way cannot pass through Gatekeeper" ([Big Sur notes][apple-bigsur]).
- LLVM's lld, which uv links with, ad-hoc signs arm64 macOS output by default too ([lld source][lld-driver]).

The signatures in the published binaries, read from their `LC_CODE_SIGNATURE` blobs, with every SHA-256 page hash recomputed and matching:

| Binary | Signature |
| --- | --- |
| ripgrep 15.2.0 `aarch64-apple-darwin` | ad-hoc, linker-signed, identifier `rg`, 4 KiB pages |
| ripgrep 15.2.0 `x86_64-apple-darwin` | none |
| rage 0.12.1 `arm64-darwin` | ad-hoc, linker-signed, identifier `rage-800e2c72d3fb9a2e`, 4 KiB pages |
| rage 0.12.1 `x86_64-darwin` | none |
| uv 0.13.1 `aarch64-apple-darwin` | CMS signature, hardened runtime flag, 16 KiB pages |
| uv 0.13.1 `x86_64-apple-darwin` | CMS signature, hardened runtime flag |

rage's identifier matches the `NAME-HASH` file name Cargo links under `target/*/deps`, so the signature carries Cargo's metadata hash.

### Gatekeeper and quarantine

- Gatekeeper verifies "when a user downloads and opens an app, a plug-in, or an installer package from outside the App Store", and "all software in macOS is checked for known malicious content the first time it's opened, regardless of how it arrived on the Mac" ([Apple Platform Security][apple-gatekeeper]).
- Apps set the `com.apple.quarantine` attribute on their downloads; `LSFileQuarantineEnabled` is the Info.plist key that makes an app's files quarantined ([key][apple-quarantine-key]). From Apple DTS: "Unix-y networking tools, like `curl` and `scp`, don't quarantine the files they download. Unix-y unarchiving tools, like `tar` and `unzip`, don't propagate quarantine to the unarchived files", while Archive Utility does. "Running a quarantined app always invokes Gatekeeper" ([DTS, 2022, revised 2025][apple-dts-trusted]). "Gatekeeper usually only kicks in [if] the app is quarantined" ([DTS, 2020][apple-dts-curl]).
- A human who downloads the archive with a browser and opens it in Finder gets quarantined files; `curl | sh` and `tar` in a terminal do not.

### Notarization

- Notarization needs a Developer ID signature, not an ad-hoc one, and the hardened runtime ([notarizing][apple-notarize]). Only the Account Holder of a team in the Apple Developer Program can create a Developer ID certificate ([Developer ID][apple-devid]).
- "Although tickets are created for standalone binaries, it's not currently possible to staple tickets to them"; Gatekeeper finds a ticket online ([customizing][apple-notarize-custom]). The action uv uses says the same, and signs with `rcodesign` on a Linux runner, with keys in Azure Key Vault ([sign-macos][astral-sign]).

### Replacing a signed binary

Apple's "Updating Mac Software": macOS caches a file's code signature in the kernel and does not flush it when the file changes in place, which can crash the updated code with `Code Signature Invalid`. The fix is to "write the updated code to a temporary file and replace the existing file with that temporary one" ([Apple][apple-updating]). ADR 0014's staged file renamed over lendk's own does that.

## CI time of a minimal matrix

Job durations from the GitHub Actions API, start to finish, including checkout and toolchain setup:

| Run | Job | Runner | Duration |
| --- | --- | --- | --- |
| ripgrep 15.2.0 ([run][rg-run-15.2.0]) | `x86_64-unknown-linux-musl`, nightly, `cross` | `ubuntu-latest` | 2 min 46 s |
| | `aarch64-unknown-linux-musl`, stable, `cross` | `ubuntu-latest` | 2 min 41 s |
| | `aarch64-apple-darwin`, nightly | `macos-latest` | 1 min 16 s |
| | `x86_64-apple-darwin`, nightly | `macos-latest` | 2 min 9 s |
| ripgrep 15.1.0 ([run][rg-run-15.1.0]) | `x86_64-unknown-linux-musl` | `ubuntu-latest` | 4 min 34 s |
| | `aarch64-apple-darwin` | `macos-latest` | 1 min 12 s |
| | `x86_64-apple-darwin` | `macos-latest` | 1 min 9 s |
| rage 0.12.1 ([run][rage-run]) | Linux x86_64, glibc | `ubuntu-22.04` | 2 min 3 s |
| | Debian package, x86_64 musl | `ubuntu-22.04` | 2 min 1 s |
| | Debian package, arm64 musl | `ubuntu-22.04` | 2 min 12 s |
| | macOS arm64 | `macos-latest` | 1 min 26 s |
| | macOS x86_64 | `macos-15-intel` | 2 min 1 s |
| lendk dev, 2026-10-19 ([run][lendk-ci-run]) | `macos` job, the bats suite; one test failed | `macos-latest` | 6 min 26 s |

ripgrep's jobs build with an LTO profile and run the binary to generate completions. rage's `Cargo.lock` lists 386 packages. No source gives a duration for a binary with fewer dependencies.

- "GitHub Actions usage is free for standard GitHub-hosted runners in public repositories" ([billing][gh-billing-concepts]). lendk's repository is public.
- For private repositories a minute costs 0.006 USD on Linux x64, 0.005 USD on Linux arm64 and 0.062 USD on macOS, and GitHub Free includes 2,000 minutes a month ([pricing][gh-billing]).
- The standard macOS labels are `macos-latest`, `macos-14`, `macos-15` and `macos-26` on arm64, and `macos-15-intel` and `macos-26-intel` on Intel ([runners][gh-runners]). GitHub announced `macos-15-intel` as available until August 2027 ([runner-images#13045][gh-intel]) and said it would stop supporting x86_64 macOS once the macOS 15 image retires in fall 2027 ([changelog][gh-macos13-changelog]). The runners page lists `macos-26-intel` without an end date.

## Release trust facts that bear on ADR 0014

ADR 0014 trusts the HTTPS release and a same-release checksum, which catches a corrupt download "not a compromised release or account", and rejects signatures because a signer's key must reach the human another way. GitHub offers three mechanisms that do not need such a key:

- **Asset digests**: since 2025-06-03 GitHub computes a SHA-256 for each uploaded release asset and shows it in the UI, the REST and GraphQL APIs and `gh` ([changelog][gh-digest]). lendk 1.1.0's two assets carry such digests in the REST API.
- **Artifact attestations**: Sigstore-signed provenance that names the workflow, repository, commit and trigger of a build. Public repositories use the Sigstore public-good instance and its public transparency log. `gh attestation verify` checks one. They are "*not* a guarantee that an artifact is secure" ([attestations][gh-attest]). They come from `actions/attest-build-provenance` in a workflow, as in all three projects above. lendk's releases are built on the maintainer's machine by `make dist` and uploaded with `gh release create` (`docs/release.md`), so no workflow builds them.
- **Immutable releases**: once published, a release's assets cannot change and its tag cannot move or be deleted, and GitHub generates a release attestation ([immutable releases][gh-immutable]). It became generally available on 2025-10-28 ([changelog][gh-immutable-ga]). `gh release verify TAG` and `gh release verify-asset TAG FILE` check them ([verify][gh-verify]). The setting is off for lendk's repository (`GET /repos/v-bonilla/lendk/immutable-releases` returns `"enabled": false`).

Each check runs where `gh` or a Sigstore client runs; `install.sh` and `lendk upgrade` use curl or wget and `sha256sum` or `shasum`.

## What this survey could not settle

- No source found states whether Apple's ld64 output is bit-identical across Xcode versions, or between ld64 and lld.
- The uv notarization tickets were not checked with Apple, which needs a Mac.
- No published CI duration was found for a Rust binary of lendk's size.

[deny-release]: https://github.com/EmbarkStudios/cargo-deny/releases/tag/0.20.2
[deny-cfg]: https://embarkstudios.github.io/cargo-deny/checks/cfg.html
[deny-adv]: https://embarkstudios.github.io/cargo-deny/checks/advisories/cfg.html
[deny-bans]: https://embarkstudios.github.io/cargo-deny/checks/bans/cfg.html
[deny-bans-overview]: https://embarkstudios.github.io/cargo-deny/checks/bans/index.html
[deny-sources]: https://embarkstudios.github.io/cargo-deny/checks/sources/cfg.html
[deny-action]: https://github.com/EmbarkStudios/cargo-deny-action/releases/tag/v2.1.1
[vet]: https://mozilla.github.io/cargo-vet/
[vet-criteria]: https://mozilla.github.io/cargo-vet/built-in-criteria.html
[vet-import]: https://mozilla.github.io/cargo-vet/importing-audits.html
[vet-ci]: https://mozilla.github.io/cargo-vet/configuring-ci.html
[vet-trusted]: https://mozilla.github.io/cargo-vet/trusting-publishers.html
[vet-crate]: https://crates.io/crates/cargo-vet
[crev]: https://github.com/crev-dev/cargo-crev
[crev-start]: https://github.com/crev-dev/cargo-crev/blob/main/cargo-crev/src/doc/getting_started.md
[crev-release]: https://github.com/crev-dev/cargo-crev/releases/tag/v0.27.1
[auditable]: https://github.com/rust-secure-code/cargo-auditable
[auditable-release]: https://github.com/rust-secure-code/cargo-auditable/releases/tag/v0.7.7
[cargo-build]: https://doc.rust-lang.org/cargo/commands/cargo-build.html
[cargo-vendor]: https://doc.rust-lang.org/cargo/commands/cargo-vendor.html
[cargo-build-scripts]: https://doc.rust-lang.org/cargo/reference/build-scripts.html
[cargo-unstable]: https://doc.rust-lang.org/cargo/reference/unstable.html
[trim-paths-pr]: https://github.com/rust-lang/cargo/pull/17488
[trim-paths-issue]: https://github.com/rust-lang/cargo/issues/12137
[cargo-8140]: https://github.com/rust-lang/cargo/issues/8140
[rustc-args]: https://doc.rust-lang.org/rustc/command-line-arguments.html
[rustc-remap]: https://doc.rust-lang.org/rustc/remap-source-paths.html
[rustc-lints]: https://doc.rust-lang.org/rustc/lints/levels.html
[rustc-platforms]: https://doc.rust-lang.org/rustc/platform-support.html
[ref-linkage]: https://doc.rust-lang.org/reference/linkage.html
[spec-x86-musl]: https://github.com/rust-lang/rust/blob/6ce0650633aeef5e17102afc94b9004df919f043/compiler/rustc_target/src/spec/targets/x86_64_unknown_linux_musl.rs#L20-L21
[spec-arm-musl]: https://github.com/rust-lang/rust/blob/f3a0d22bb5e080f25801e8241a4edb71a9304457/compiler/rustc_target/src/spec/targets/aarch64_unknown_linux_musl.rs#L18-L19
[mcp-422]: https://github.com/rust-lang/compiler-team/issues/422
[clippy-disallowed]: https://github.com/rust-lang/rust-clippy/blob/01ffa188523fcf0831dfd6a328f583973d188b1e/clippy_lints/src/disallowed_types.rs
[rb-rust]: https://reproducible-builds.org/docs/rust/
[rb-sde]: https://reproducible-builds.org/docs/source-date-epoch/
[rb-archives]: https://reproducible-builds.org/docs/archives/
[rb-debian-rg]: https://tests.reproducible-builds.org/debian/rb-pkg/trixie/amd64/rust-ripgrep.html
[rg-release]: https://github.com/BurntSushi/ripgrep/blob/dffd776a737dc19a48b758dd6a621de113794121/.github/workflows/release.yml
[rg-release-draft]: https://github.com/BurntSushi/ripgrep/blob/dffd776a737dc19a48b758dd6a621de113794121/.github/workflows/release.yml#L37-L40
[rg-release-matrix]: https://github.com/BurntSushi/ripgrep/blob/dffd776a737dc19a48b758dd6a621de113794121/.github/workflows/release.yml#L64-L138
[rg-release-macos]: https://github.com/BurntSushi/ripgrep/blob/dffd776a737dc19a48b758dd6a621de113794121/.github/workflows/release.yml#L115-L122
[rg-release-cross]: https://github.com/BurntSushi/ripgrep/blob/dffd776a737dc19a48b758dd6a621de113794121/.github/workflows/release.yml#L156-L169
[rg-release-build]: https://github.com/BurntSushi/ripgrep/blob/dffd776a737dc19a48b758dd6a621de113794121/.github/workflows/release.yml#L184-L193
[rg-release-strip]: https://github.com/BurntSushi/ripgrep/blob/dffd776a737dc19a48b758dd6a621de113794121/.github/workflows/release.yml#L195-L198
[rg-release-sum]: https://github.com/BurntSushi/ripgrep/blob/dffd776a737dc19a48b758dd6a621de113794121/.github/workflows/release.yml#L278-L285
[rg-release-attest]: https://github.com/BurntSushi/ripgrep/blob/dffd776a737dc19a48b758dd6a621de113794121/.github/workflows/release.yml#L287-L290
[rg-config]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/.cargo/config.toml#L10-L21
[rg-checklist]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/RELEASE-CHECKLIST.md
[rg-readme]: https://github.com/BurntSushi/ripgrep/blob/3fce3b5bb0236da2df6d99672afb8a719642eca7/README.md#installation
[rg-15.2.0]: https://github.com/BurntSushi/ripgrep/releases/tag/15.2.0
[rg-run-15.2.0]: https://github.com/BurntSushi/ripgrep/actions/runs/29431117779
[rg-run-15.1.0]: https://github.com/BurntSushi/ripgrep/actions/runs/18716398524
[rage-release]: https://github.com/str4d/rage/blob/d25573888a2dd9ae0ec0532efb7f1dcd7535d358/.github/workflows/release.yml#L33-L64
[rage-release-macos]: https://github.com/str4d/rage/blob/d25573888a2dd9ae0ec0532efb7f1dcd7535d358/.github/workflows/release.yml#L71-L79
[rage-release-build]: https://github.com/str4d/rage/blob/d25573888a2dd9ae0ec0532efb7f1dcd7535d358/.github/workflows/release.yml#L99-L101
[rage-release-attest]: https://github.com/str4d/rage/blob/d25573888a2dd9ae0ec0532efb7f1dcd7535d358/.github/workflows/release.yml#L121-L124
[rage-release-upload]: https://github.com/str4d/rage/blob/d25573888a2dd9ae0ec0532efb7f1dcd7535d358/.github/workflows/release.yml#L133-L141
[rage-release-deb]: https://github.com/str4d/rage/blob/d25573888a2dd9ae0ec0532efb7f1dcd7535d358/.github/workflows/release.yml#L232-L285
[rage-audits]: https://github.com/str4d/rage/blob/b5b68c4f4f7ea5c368bc060f6fe0237549c3a13f/.github/workflows/audits.yml
[rage-audit]: https://github.com/str4d/rage/blob/b5b68c4f4f7ea5c368bc060f6fe0237549c3a13f/.github/workflows/audit.yml
[rage-vet]: https://github.com/str4d/rage/blob/b5b68c4f4f7ea5c368bc060f6fe0237549c3a13f/supply-chain/config.toml
[rage-vet-audits]: https://github.com/str4d/rage/blob/b5b68c4f4f7ea5c368bc060f6fe0237549c3a13f/supply-chain/audits.toml
[rage-vet-imports]: https://github.com/str4d/rage/blob/b5b68c4f4f7ea5c368bc060f6fe0237549c3a13f/supply-chain/imports.lock
[rage-lock]: https://github.com/str4d/rage/blob/b5b68c4f4f7ea5c368bc060f6fe0237549c3a13f/Cargo.lock
[rage-toolchain]: https://github.com/str4d/rage/blob/b5b68c4f4f7ea5c368bc060f6fe0237549c3a13f/rust-toolchain.toml
[rage-readme]: https://github.com/str4d/rage/blob/b5b68c4f4f7ea5c368bc060f6fe0237549c3a13f/README.md#installation
[rage-0.12.1]: https://github.com/str4d/rage/releases/tag/v0.12.1
[rage-run]: https://github.com/str4d/rage/actions/runs/29302689689
[uv-release]: https://github.com/astral-sh/uv/blob/f448faef39ac93cf6f0900638425968936ffa09b/.github/workflows/release.yml
[uv-release-gate]: https://github.com/astral-sh/uv/blob/f448faef39ac93cf6f0900638425968936ffa09b/.github/workflows/release.yml#L37-L51
[uv-release-attest]: https://github.com/astral-sh/uv/blob/f448faef39ac93cf6f0900638425968936ffa09b/.github/workflows/release.yml#L399-L407
[uv-build-macos]: https://github.com/astral-sh/uv/blob/f448faef39ac93cf6f0900638425968936ffa09b/.github/workflows/build-release-binaries.yml#L197-L274
[uv-sign]: https://github.com/astral-sh/uv/blob/f448faef39ac93cf6f0900638425968936ffa09b/.github/workflows/sign-release-binaries.yml#L140-L183
[uv-policies]: https://github.com/astral-sh/uv/blob/f448faef39ac93cf6f0900638425968936ffa09b/.github/workflows/check-crates-policies.yml
[uv-dist]: https://github.com/astral-sh/uv/blob/63ef84e362a7bee02bc54f0a0707523da24d41ea/dist-workspace.toml
[uv-install-doc]: https://github.com/astral-sh/uv/blob/f448faef39ac93cf6f0900638425968936ffa09b/docs/getting-started/installation.md
[uv-0.13.1]: https://github.com/astral-sh/uv/releases/tag/0.13.1
[uv-installer]: https://github.com/astral-sh/uv/releases/download/0.13.1/uv-installer.sh
[astral-sign]: https://github.com/astral-sh/github-actions/blob/bc129f0373fce6ac3089ca20b7f62c04f441e841/sign-macos/README.md
[dist-release]: https://github.com/axodotdev/cargo-dist/releases/tag/v0.33.0
[dist-checksums]: https://axodotdev.github.io/cargo-dist/book/artifacts/checksums.html
[apple-bigsur]: https://developer.apple.com/documentation/macos-release-notes/macos-big-sur-11_0_1-universal-apps-release-notes
[apple-updating]: https://developer.apple.com/documentation/security/updating-mac-software
[apple-notarize]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
[apple-notarize-custom]: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
[apple-quarantine-key]: https://developer.apple.com/documentation/bundleresources/information-property-list/lsfilequarantineenabled
[apple-devid]: https://developer.apple.com/developer-id/
[apple-gatekeeper]: https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web
[apple-dts-trusted]: https://developer.apple.com/forums/thread/706442
[apple-dts-curl]: https://developer.apple.com/forums/thread/666452
[lld-driver]: https://github.com/llvm/llvm-project/blob/27e2fc2de79d78efef0dabef0aa6ecde26fb89c3/lld/MachO/Driver.cpp#L1217-L1225
[gh-billing]: https://docs.github.com/en/billing/concepts/product-billing/github-actions
[gh-billing-concepts]: https://docs.github.com/en/actions/concepts/billing-and-usage
[gh-runners]: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
[gh-intel]: https://github.com/actions/runner-images/issues/13045
[gh-macos13-changelog]: https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/
[gh-attest]: https://docs.github.com/en/actions/concepts/security/artifact-attestations
[gh-immutable]: https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases
[gh-immutable-ga]: https://github.blog/changelog/2025-10-28-immutable-releases-are-now-generally-available/
[gh-verify]: https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity
[gh-digest]: https://github.blog/changelog/2025-06-03-releases-now-expose-digests-for-release-assets/
[lendk-ci-run]: https://github.com/v-bonilla/lendk/actions/runs/39276648700
