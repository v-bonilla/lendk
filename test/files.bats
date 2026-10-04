#!/usr/bin/env bats
# NFR2 backend call counts per verb and NFR5 writes: a filesystem snapshot around every verb, and
# TMPDIR empty after exit and at exec.
# shellcheck disable=SC2012,SC2016

setup() {
	load helpers/common
	sandbox
	MAP=$HOME/.config/lendk/map
	SHIMS=$HOME/.local/share/lendk/shims
	mkdir -p "$HOME/.config/lendk" && chmod 700 "$HOME/.config/lendk"
	printf '@g K2 K3\nstub K1 @g\ntmpls K1\n' >"$MAP"
	chmod 600 "$MAP"
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	ln -s "$FIXTURES/stub-target" "$SB/bin/other"
	printf '#!/bin/sh\nls -A "$TMPDIR" >"$STUB_LOG/tmp-at-exec"\n' >"$SB/bin/tmpls"
	chmod +x "$SB/bin/tmpls"
	for k in K1 K2 K3 K4; do printf '%s-%s\n' "$SENTINEL" "$k" >"$SB/store/env/$k.gpg"; done
	run_lendk sync
	assert_eq "$status" 0
	export PATH=$SHIMS:$PATH
	rm -rf "$SB/log"/*
}

# calls: the number of backend reads so far.
calls() {
	local c=("$SB"/log/pass.*)
	[[ -e ${c[0]} ]] || c=()
	printf '%s\n' "${#c[@]}"
}

# verb ARG...: run_lendk ARG..., then TMPDIR is empty.
verb() {
	run_lendk "$@"
	assert_eq "$(ls -A "$TMPDIR")" ""
}

@test "NFR2: run reads each key the caller did not set, once, and unlock each key it names" {
	verb run -- stub
	assert_eq "$status" 0
	assert_eq "$(calls)" 3
	rm -rf "$SB/log"/*
	K1=preset verb run -- stub
	assert_eq "$(calls)" 2
	rm -rf "$SB/log"/*
	verb run K4 @g -- stub
	assert_eq "$(calls)" 3
	rm -rf "$SB/log"/*
	verb unlock K1 K4
	assert_eq "$output" unlocked
	assert_eq "$(calls)" 2
}

@test "NFR2: check, sync, add, rm, init, --help and --version make no backend read" {
	verb check
	verb sync
	verb add stub K4
	verb rm stub K4
	verb init sh
	verb --help
	verb --version
	assert_eq "$(calls)" 0
}

@test "NFR5: run, unlock, check, init, --help and --version leave the filesystem unchanged" {
	local before
	before=$(snapshot)
	verb run -- stub
	verb run K4 -- stub
	verb unlock
	verb check
	verb init bash
	verb --help
	verb --version
	printf 'locked\n' >"$SB/store/env/K2.mode"
	verb run -- stub
	assert_class locked 120
	rm "$SB/store/env/K2.mode"
	rm -rf "$SB/log"/*
	assert_eq "$(snapshot)" "$before"
}

@test "NFR5: sync, add and rm write only the map, its directory and the shim directory" {
	local before after
	before=$(snapshot | grep -v "$HOME/.config/lendk\|$SHIMS")
	verb add other K4
	verb add stub K4
	verb rm other
	verb sync
	after=$(snapshot | grep -v "$HOME/.config/lendk\|$SHIMS")
	assert_eq "$after" "$before"
	[[ ! -e $SHIMS.lock ]]
	assert_eq "$(ls -ldn "$MAP" | cut -c1-10)" -rw-------
}

@test "NFR5: TMPDIR is empty when the target starts" {
	run_lendk run -- tmpls
	assert_eq "$status" 0
	assert_eq "$(calls)" 1
	[[ -f $STUB_LOG/tmp-at-exec && ! -s $STUB_LOG/tmp-at-exec ]]
	assert_eq "$(ls -A "$TMPDIR")" ""
}
