#!/bin/sh
# PROTOTYPE for #33, throwaway. Claim 1: @u keeps a user key after the user's last process exits.
set -u
. "$(dirname "$0")/lib.sh"
say "claim 1: @u outlives alice's last process ($(stamp))"
as_ops 'echo "kernel $(uname -r)"; loginctl show-user alice -p Linger 2>&1; grep -H pam_keyinit /etc/pam.d/* 2>/dev/null'
as_alice 'keyprobe ctx; keyprobe put lendk:claim1 3600 staged c1'
alice_gone
sleep 60
alice_gone
as_alice 'echo "$(date -u +%H:%M:%S) new login:"; keyprobe get lendk:claim1 plain'
