# PROTOTYPE for #33, throwaway: helpers the claim scripts source. Every command runs in the VM
# that vm/up.sh boots, over ssh from inside its container, so each `as_alice` call is a fresh login with its own session keyring.
ssh_vm() {
	user=$1
	shift
	# From inside the QEMU container, with a key exchange TCG can afford: about 12 s a login.
	docker exec -i lendk-proto33-vm ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR -o ConnectTimeout=300 -o GSSAPIAuthentication=no -o KexAlgorithms=curve25519-sha256 \
		-o Ciphers=aes128-ctr -o MACs=hmac-sha2-256 -p 2222 -i /vm/id_proto33 "$user@127.0.0.1" "$@"
}
as_alice() { ssh_vm alice "$@"; }
as_ops() { ssh_vm ops "$@"; }
say() { printf '\n## %s\n' "$*"; }
stamp() { date -u +%H:%M:%S; }
# alice_gone: wait until alice has no process left in the VM, then show it.
alice_gone() {
	as_ops 'for i in $(seq 120); do pgrep -u alice >/dev/null || break; sleep 1; done
		echo "$(date -u +%H:%M:%S) alice processes: $(pgrep -u alice | wc -l)"
		echo "key-users (uid: usage nkeys/nikeys ...):"; sudo cat /proc/key-users'
}
# alice_logged_out: wait until alice has no login session left, then show what still runs as alice.
alice_logged_out() {
	as_ops 'for i in $(seq 120); do loginctl list-sessions --no-legend | grep -qw alice || break; sleep 1; done
		echo "$(date -u +%H:%M:%S) alice sessions: $(loginctl list-sessions --no-legend | grep -cw alice); processes: $(pgrep -u alice -l | tr "\n" " ")"'
}
