#!/bin/sh
# PROTOTYPE for #33, throwaway. Claim 4: which errno Docker's and Podman's default seccomp
# profiles give add_key and keyctl. `syscalls` touches only the thread keyring and a fresh session
# keyring; `get` searches @u, which a rootless container has its own of.
set -u
. "$(dirname "$0")/lib.sh"
say "claim 4 ($(stamp))"
as_ops 'docker --version; podman --version; dpkg-query -W golang-github-containers-common 2>/dev/null; ls /usr/share/containers/seccomp.json 2>&1'
as_ops 'sudo docker pull -q ubuntu:24.04 >/dev/null; sudo podman pull -q docker.io/library/ubuntu:24.04 >/dev/null
	for opt in "" "--security-opt seccomp=unconfined"; do
		echo "-- docker run $opt"
		sudo docker run --rm $opt -v /usr/local/bin/keyprobe:/kp:ro ubuntu:24.04 sh -c "/kp syscalls; /kp get lendk:claim4 plain; /kp put lendk:claim4 60 staged c4"
	done
	echo "-- podman run, rootful"
	sudo podman run --rm -v /usr/local/bin/keyprobe:/kp:ro docker.io/library/ubuntu:24.04 sh -c "/kp syscalls; /kp get lendk:claim4 plain; /kp put lendk:claim4 60 staged c4"'
as_alice 'echo "-- podman run, rootless"; podman pull -q docker.io/library/ubuntu:24.04 >/dev/null
	podman run --rm -v /usr/local/bin/keyprobe:/kp:ro docker.io/library/ubuntu:24.04 sh -c "/kp syscalls; /kp ctx; /kp get lendk:claim4 plain; /kp put lendk:claim4 60 staged c4"'
