#!/bin/sh
# PROTOTYPE for #33, throwaway. Claim 6: an identity file at scrypt 2^18 opens in a few seconds
# on a slow machine, and the age crate opens it under a 2^22 limit; Go age reads the crate's file
# and the crate reads Go age's. Run on the VM, whose QEMU TCG CPU stands in for a slow machine.
set -u
. "$(dirname "$0")/lib.sh"
say "claim 6 ($(stamp))"
as_alice 'mkdir -p "$HOME/claim6" && cd "$HOME/claim6" && export PROTO33_PASSPHRASE=proto33-throwaway-passphrase
	echo "age $(age --version)"
	agetime write id18.age 18
	for i in 1 2; do agetime open id18.age 22; done
	agetime open id18.age default
	echo "-- Go age opens the crate file:"; python3 /tmp/proto33/goage.py "$PROTO33_PASSPHRASE" age -d -o /dev/null id18.age && echo "go-age-decrypt=ok"
	echo "-- Go age writes with age -p:"; printf "stand-in identity\n" >plain.txt
	python3 /tmp/proto33/goage.py "$PROTO33_PASSPHRASE" age -p -o go.age plain.txt && grep -a "^-> scrypt" go.age | cut -d" " -f1,2,4
	agetime open go.age 22'
