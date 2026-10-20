#!/bin/sh
# Build both targets on one simulated host, in a container.
#   ./host.sh a|b
# a: debian:trixie, root, HOME=/root, built in /src/lendk
# b: ubuntu:24.04, user alice (uid 1500), HOME=/home/alice,
#    built in /home/alice/w/deep/build-dir, other TZ, umask and locale
set -eu
here=$(cd "$(dirname "$0")" && pwd)
host=$1
sde=${SOURCE_DATE_EPOCH:?set SOURCE_DATE_EPOCH}
mkdir -p "$here/out/$host"
case $host in
a) image=debian:trixie user=root home=/root dir=/src/lendk tz=UTC um=022 ;;
b) image=ubuntu:24.04 user=alice home=/home/alice dir=/home/alice/w/deep/build-dir tz=Asia/Tokyo um=077 ;;
*) echo "usage: $0 a|b" >&2; exit 2 ;;
esac
nice -n 19 docker run --rm --cpus 3 --hostname "host-$host" \
	-e SOURCE_DATE_EPOCH="$sde" -e TZ="$tz" \
	-v "$here:/in:ro" -v "$here/out/$host:/out" "$image" sh -euc "
apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends curl ca-certificates gcc libc6-dev >/dev/null
[ $user = root ] || useradd -m -u 1500 $user
mkdir -p $dir && cp -r /in/Cargo.toml /in/Cargo.lock /in/rust-toolchain.toml /in/src /in/build.sh $dir/
chown -R $user $dir
su $user -c '
umask $um
export HOME=$home LANG=C.UTF-8
curl -sSf --proto =https https://sh.rustup.rs | sh -s -- -y -q --profile minimal --default-toolchain none
. \$HOME/.cargo/env
cd $dir
rustup show active-toolchain >/dev/null 2>&1 || rustup toolchain install >/dev/null
rustc -Vv
cargo -V
./build.sh x86_64-unknown-linux-musl /tmp/o
./build.sh aarch64-unknown-linux-musl /tmp/o
'
cp -r /tmp/o/. /out/ && chown -R $(id -u):$(id -g) /out
cat /etc/os-release | head -2; id $user
"
