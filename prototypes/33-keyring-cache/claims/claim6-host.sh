#!/bin/sh
# PROTOTYPE for #33, throwaway. Claim 6 on the host, which no keyring call reaches: write identity
# files at 2^18, 2^22 and 2^23, then open them at full speed, under CPU quotas standing in for
# slower machines, and under memory limits. Usage: claims/claim6-host.sh AGETIME DIR
set -u
agetime=$1
dir=$2
export PROTO33_PASSPHRASE=proto33-throwaway-passphrase
cd "$dir" || exit 1
for n in 18 22 23; do "$agetime" write "id$n.age" "$n"; done
for i in 1 2 3; do "$agetime" open id18.age 22; done
"$agetime" open id18.age default
"$agetime" open id22.age 22
"$agetime" open id23.age 22
run() { docker run --rm --network none --user 4242 -e PROTO33_PASSPHRASE -v "$agetime:/agetime:ro" -v "$dir:/age:ro" "$@"; }
for c in 0.5 0.25 0.1; do
	echo "cpus=$c"
	run --cpus "$c" ubuntu:24.04 sh -c '/agetime open /age/id18.age 22; /agetime open /age/id18.age default'
done
echo "memory 512 MiB, the 2^18 file"
run --memory 512m --memory-swap 512m ubuntu:24.04 /agetime open /age/id18.age 22
echo "memory 2 GiB, the 2^22 file"
run --memory 2g --memory-swap 2g ubuntu:24.04 sh -c '/agetime open /age/id22.age 22; echo "exit=$?"'
