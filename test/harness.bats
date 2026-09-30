#!/usr/bin/env bats
# The helpers the suite relies on.

setup() {
	load helpers/common
	sandbox
}

@test "sandbox: HOME, TMPDIR and the store are private, and no key or lend variable leaks in" {
	assert_eq "$HOME" "$SB/home"
	assert_eq "$TMPDIR" "$SB/tmp"
	assert_eq "$PASSWORD_STORE_DIR" "$SB/store"
	local leaked
	leaked=$(compgen -e | grep -E '^(XDG_|LEND_|GNUPGHOME$|GH_TOKEN$|.*_(TOKEN|KEY|SECRET)$)' || true)
	assert_eq "$leaked" ""
	[[ $SENTINEL == lend-sentinel-?* ]]
}

@test "fake-pass: prints the entry and logs argv, environment and PID" {
	printf '%s\nsecond\n' "$SENTINEL" >"$SB/store/env/K.gpg"
	run pass show env/K
	assert_eq "$status" 0
	assert_eq "$output" "$SENTINEL"$'\nsecond'
	local log=("$SB"/log/pass.*)
	assert_eq "${#log[@]}" 1
	assert_eq "$(tr '\0' ' ' <"${log[0]}/argv")" "show env/K "
	tr '\0' '\n' <"${log[0]}/env" | grep -qx "HOME=$HOME"
	[[ -s ${log[0]}/pid ]]
}

@test "fake-pass: a missing entry fails like pass" {
	run pass show env/NOPE
	assert_eq "$status" 1
	assert_eq "$output" "Error: env/NOPE is not in the password store."
}

@test "stub-target: logs argv0, arguments and environment, and exits STUB_EXIT" {
	STUB_EXIT=7 run "$FIXTURES/stub-target" a 'b c'
	assert_eq "$status" 7
	local log=("$SB"/log/target.*)
	assert_eq "$(<"${log[0]}/argv0")" "$FIXTURES/stub-target"
	assert_eq "$(tr '\0' '|' <"${log[0]}/argv")" "a|b c|"
}

@test "run_lend: rejects a stderr line outside the contract" {
	printf '#!/bin/sh\necho "raw error" >&2\n' >"$SB/bin/fake-lend"
	chmod +x "$SB/bin/fake-lend"
	# shellcheck disable=SC2034
	LEND=$SB/bin/fake-lend
	run run_lend
	assert_eq "$status" 1
	assert_line "$output" "stderr line breaks the contract: raw error"
}

@test "run_lend: rejects a non-interactive forbidden suggestion" {
	printf '#!/bin/sh\necho "lend: unmapped: gh is not mapped. Map it: lend add gh KEY" >&2\n' >"$SB/bin/fake-lend"
	chmod +x "$SB/bin/fake-lend"
	# shellcheck disable=SC2034
	LEND=$SB/bin/fake-lend
	run run_lend
	assert_eq "$status" 1
	LEND_PROMPT=allow run run_lend
	assert_eq "$status" 0
}

@test "run_lend: captures stdout, stderr and status with stdin at /dev/null" {
	printf '#!/bin/sh\ncat; echo out; echo "lend: map: m:1: bad. Fix the line, then run: lend check" >&2; exit 125\n' >"$SB/bin/fake-lend"
	chmod +x "$SB/bin/fake-lend"
	# shellcheck disable=SC2034
	LEND=$SB/bin/fake-lend
	run_lend
	assert_eq "$output" out
	assert_class map 125
}

@test "gone: a live process is not gone, a zombie and a reaped one are" {
	sleep 30 &
	local live=$!
	if gone "$live"; then false; fi
	kill "$live"
	wait "$live" || true
	gone "$live"
	sh -c 'sleep 0.1 & exec sleep 30' &
	local parent=$! zombie ppid
	sleep 0.5
	local stat f
	for f in /proc/[0-9]*/stat; do
		read -r stat 2>/dev/null <"$f" || continue
		stat=${stat##*) }
		read -r _ ppid _ <<<"$stat"
		[[ $ppid == "$parent" ]] && zombie=${f#/proc/} && zombie=${zombie%/stat}
	done
	[[ -n ${zombie-} ]]
	gone "$zombie"
	kill "$parent"
	wait "$parent" || true
}

@test "require: skips an absent tool and fails one TEST_REQUIRE lists" {
	run require lend-no-such-tool
	assert_eq "$status" 0
	TEST_REQUIRE="lend-no-such-tool" run require lend-no-such-tool
	assert_eq "$status" 1
}

@test "require: every tool TEST_REQUIRE lists is present" {
	local tool
	for tool in ${TEST_REQUIRE-}; do
		require "$tool"
	done
}
