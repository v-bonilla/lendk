#!/bin/sh
# Print the SHA-256 of every rlib, object and final binary of one build, with
# paths relative to the target directory, so two builds' lists diff directly:
#   ./hashes.sh TARGET [TARGET_DIR]
set -eu
target=$1 dir=${2:-target}
cd "$dir"
find release/deps "$target/release/deps" -type f \( -name '*.rlib' -o -name '*.o' \) 2>/dev/null |
	LC_ALL=C sort | xargs -r sha256sum
sha256sum "$target/release/lendk-proto" "$target/release/probe"
