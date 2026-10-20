#!/bin/sh
# PROTOTYPE for #33, throwaway. Claim 3: a possessor-only user key with an expiry reads back in a
# fresh process into the caller's buffer, then gives EKEYEXPIRED, then ENOKEY after gc_delay.
set -u
. "$(dirname "$0")/lib.sh"
say "claim 3 ($(stamp)): gc_delay=$(as_ops 'cat /proc/sys/kernel/keys/gc_delay')"
as_alice 'keyprobe put lendk:claim3 120 staged c3; keyprobe put lendk:claim3d 900 direct d'
say "a fresh login reads both"
as_alice 'keyprobe get lendk:claim3 plain; keyprobe get lendk:claim3d plain'
say "a fresh process outside the login's session keyring (an anonymous one, as a container or service has)"
as_alice 'keyprobe join-session -- keyprobe ctx; keyprobe join-session -- keyprobe get lendk:claim3 plain; keyprobe join-session -- keyprobe get lendk:claim3 possess'
say "replacing the key displaces it in one step"
as_alice 'keyprobe put lendk:claim3d 900 staged d2; keyprobe get lendk:claim3d plain'
say "lock, from inside and outside the login's session keyring"
as_alice 'keyprobe join-session -- keyprobe lock lendk:claim3d plain; keyprobe join-session -- keyprobe lock lendk:claim3d possess; keyprobe get lendk:claim3d plain'
say "expiry and garbage collection: a fresh keyprobe process every 2 s, inside one login"
as_alice 'keyprobe put lendk:claim3e 30 staged e | sed "s/ proc_keys=.*//"; t0=$(date +%s); last=
	while :; do
		r=$(keyprobe get lendk:claim3e plain | sed "s/ serial=.*//; s/ how=.*//")
		[ "$r" != "$last" ] && echo "t+$(( $(date +%s) - t0 ))s $r"
		last=$r
		case $r in *ENOKEY*) break ;; esac
		[ $(( $(date +%s) - t0 )) -gt 600 ] && break
		sleep 2
	done'
