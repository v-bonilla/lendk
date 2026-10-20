#!/bin/sh
# The release build command under test. Run from the crate directory:
#   ./build.sh TARGET OUTDIR
# Needs rustup with the toolchain from rust-toolchain.toml, and a host cc for
# build scripts and proc macros only; the target binaries need no system
# linker: rust-lld and the toolchain's self-contained musl link them.
set -eu
target=$1 out=$2
: "${CARGO_HOME:=$HOME/.cargo}" "${RUSTUP_HOME:=$HOME/.rustup}"
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git log -1 --pretty=%ct 2>/dev/null || echo 0)}
export SOURCE_DATE_EPOCH
RUSTFLAGS="-C linker=rust-lld -C link-self-contained=yes -C target-feature=+crt-static"
RUSTFLAGS="$RUSTFLAGS --remap-path-scope=all"
RUSTFLAGS="$RUSTFLAGS --remap-path-prefix=$CARGO_HOME=/cargo"
RUSTFLAGS="$RUSTFLAGS --remap-path-prefix=$RUSTUP_HOME=/rustup"
RUSTFLAGS="$RUSTFLAGS --remap-path-prefix=$PWD=/src"
export RUSTFLAGS
cargo build --release --locked --target "$target" --bins -j 3
mkdir -p "$out/$target"
cp "target/$target/release/lendk-proto" "target/$target/release/probe" "$out/$target/"
