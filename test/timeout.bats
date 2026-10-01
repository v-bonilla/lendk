#!/usr/bin/env bats
# FR16: LENDK_TIMEOUT bounds all backend work of a call, cleanup included.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034

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

# timed_lendk ARG...: run_lendk ARG..., with its wall time in seconds in elapsed.
timed_lendk() {
	local TIMEFORMAT=%R
	{ time run_lendk "$@"; } 2>"$SB/time"
	elapsed=$(<"$SB/time")
}

# within LOW HIGH: LOW <= elapsed < HIGH, in whole and tenth seconds.
within() {
	local t=${elapsed/./}
	t=$((10#${t:0:${#t}-2}))
	((t >= $1 * 10 && t < $2 * 10)) || { echo "took $elapsed s, expected [$1, $2)" >&2; return 1; }
}

@test "FR16: a hanging backend gives timeout after LENDK_TIMEOUT and before LENDK_TIMEOUT + 2 s" {
	local mode
	for mode in hang stubborn; do
		echo "$mode" >"$SB/store/env/K1.mode"
		LENDK_TIMEOUT=2 timed_lendk run -- stub
		assert_eq "$stderr" "lendk: timeout: env/K1: gpg did not finish within 2 s. Ask the user to run 'lendk unlock K1' in a terminal, then retry."
		assert_class timeout 120
		within 2 4
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
