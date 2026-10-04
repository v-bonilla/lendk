#!/usr/bin/env bats
# FR16: LENDK_TIMEOUT bounds all backend work of a call, cleanup included.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2154

setup() {
	load helpers/common
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	export LENDK_SHIMS=$SB/shims
	mkdir -p "$LENDK_SHIMS" "$HOME/.config/lendk" && chmod 700 "$LENDK_SHIMS" "$HOME/.config/lendk"
	printf 'stub K1 K2 K3\n' >"$HOME/.config/lendk/map"
	chmod 600 "$HOME/.config/lendk/map"
	local k
	for k in K1 K2 K3; do printf 'value-%s\n' "$k" >"$SB/store/env/$k.gpg"; done
}

# before_tenths N: elapsed < N tenths of a second; appends elapsed to BATS_FR16_TIMES when set.
before_tenths() {
	local t=${elapsed/./}
	t=$((10#$t))
	printf '%s\n' "$elapsed" >>"${BATS_FR16_TIMES:-/dev/null}"
	printf '# FR16 elapsed %s s\n' "$elapsed" >&3
	((t < $1 * 100)) || { echo "took $elapsed s, expected under $(($1 / 10)).$(($1 % 10)) s" >&2; return 1; }
}

@test "FR16: a hanging backend gives timeout after LENDK_TIMEOUT and before LENDK_TIMEOUT + 2 s" {
	local mode
	for mode in hang stubborn; do
		echo "$mode" >"$SB/store/env/K1.mode"
		LENDK_TIMEOUT=2 timed_lendk run -- stub
		assert_eq "$stderr" "lendk: timeout: env/K1: gpg did not finish within 2 s. Ask the user to run 'lendk unlock K1' in a terminal, then retry."
		assert_class timeout 120
		within 2 4
		# The implementation margin: LENDK_TIMEOUT + 1.5 s, plus 0.2 s for the harness.
		before_tenths 32
		assert_eq "$(compgen -G "$SB/log/target.*")" ""
		assert_eq "$(ls -A "$TMPDIR")" ""
	done
}

@test "FR16: the bound covers every key of the call, not each key" {
	local k
	for k in K1 K2 K3; do echo slow >"$SB/store/env/$k.mode"; done
	LENDK_TIMEOUT=2 timed_lendk run -- stub
	assert_class timeout 120
	refute_contains "$stderr" env/K1
	within 2 4
	LENDK_TIMEOUT=5 timed_lendk run -- stub
	assert_eq "$status" 0
}

@test "FR16: a caller's EPOCHREALTIME, garbage or frozen, cannot stretch the bound under bash 4.4" {
	local v
	echo hang >"$SB/store/env/K1.mode"
	for v in abc 1700000000.000000; do
		printf '#!/bin/sh\nexec env EPOCHREALTIME=%s %s "$@"\n' "$v" "$LENDK" >"$SB/poisoned"
		chmod +x "$SB/poisoned"
		LENDK=$SB/poisoned LENDK_TIMEOUT=2 timed_lendk run -- stub
		assert_class timeout 120
		within 2 4
		before_tenths 32
		assert_eq "$(ls -A "$TMPDIR")" ""
	done
}
