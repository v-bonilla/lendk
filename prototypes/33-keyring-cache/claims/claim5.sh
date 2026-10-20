#!/bin/sh
# PROTOTYPE for #33, throwaway. Claim 5: a fresh session keyring per suite run, a keyring per test
# inside it, no keyutils needed, in the VM and in the lendk-test:ubuntu image under Docker.
set -u
. "$(dirname "$0")/lib.sh"
say "claim 5 ($(stamp))"
say "5a: in a plain login, the guard refuses"
as_alice 'keyprobe guard'
say "5b: perl-join (no keyutils binary used) around the simulated suite, in the VM"
as_alice 'keyprobe ctx | grep user_keyring; sh /tmp/proto33/perl-join.sh sh /tmp/proto33/suite-sim.sh; keyprobe ctx | grep user_keyring'
say "5c: the lendk-test:ubuntu image, as make check-docker runs it (-u 1000:1000)"
as_ops 'sudo docker run --rm -u 1000:1000 -e HOME=/tmp lendk-test:ubuntu sh -c "command -v keyctl || echo no keyctl; command -v perl"
	for opt in "" "--security-opt seccomp=/tmp/proto33/profile.json"; do
		echo "-- docker run $opt"
		sudo docker run --rm -u 1000:1000 -e HOME=/tmp -e KP=/kp $opt -v /usr/local/bin/keyprobe:/kp:ro -v /tmp/proto33:/p:ro lendk-test:ubuntu \
			sh -c "/kp ctx; sh /p/perl-join.sh sh /p/suite-sim.sh"
	done'
say "5d: the container's @u is the VM's uid 1000's own (ops here; the developer on a typical host)"
as_ops 'echo "ops @u: $(keyprobe ctx | grep -o "user=ok:[0-9]*")"'
say "5e: a second process joining a named session keyring by name, with the holder's default perms and with user search added"
as_alice 'for share in "" share; do
	keyprobe join-session proto33-named$share $share -- sleep 30 & sleep 2
	echo "-- second process joins proto33-named$share (holder perms: ${share:-default})"
	keyprobe join-session proto33-named$share -- keyprobe ctx 2>&1 | grep "^session="
	kill $! 2>/dev/null; wait 2>/dev/null
done'
