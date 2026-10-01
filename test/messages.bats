#!/usr/bin/env bats
# FR19: every class line fail prints follows PRD 5.3 in both modes; run_lendk checks each line.
# shellcheck disable=SC2016

setup() {
	load helpers/common
	sandbox
}

# fail_line [ENV=VALUE...] -- ID TEXT [TOKEN=VALUE...]: run lendk's fail through run_lendk.
fail_line() {
	local vars=()
	while [[ $1 != -- ]]; do vars+=("$1"); shift; done
	shift
	# shellcheck disable=SC2034
	local LENDK=$SB/bin/lendk-fn
	((${#vars[@]} == 0)) || export "${vars[@]}"
	run_lendk fail "$@"
}

@test "FR19: every class gives one contract line and its exit hint, in both modes" {
	local row id hint mode
	while IFS= read -r row; do
		id=${row%%|*}
		hint=${row#*|}
		hint=${hint%%|*}
		for mode in never allow; do
			fail_line LENDK_PROMPT=$mode -- "$id" "planted text for $id"
			[[ $stderr == "lendk: ${id%%:*}: planted text for $id. "* ]]
			assert_class "${id%%:*}" "$hint"
		done
	done < <(LENDK=$SB/bin/lendk-fn; "$LENDK" eval 'printf "%s\n" "${classes[@]}"')
}

@test "FR19: non-interactive FIXes follow 5.3" {
	fail_line LENDK_PROMPT=never -- locked "env/K needs the gpg passphrase and this call cannot prompt" KEY=K
	assert_eq "$stderr" "lendk: locked: env/K needs the gpg passphrase and this call cannot prompt. Ask the user to run 'lendk unlock K' in a terminal, then retry."
	fail_line LENDK_PROMPT=never -- not-found "gh is not on PATH outside /s" CMD=gh
	assert_eq "$stderr" "lendk: not-found: gh is not on PATH outside /s. Install gh, or ask the user."
	fail_line LENDK_PROMPT=never -- unmapped "gh is not mapped" CMD=gh
	assert_eq "$stderr" "lendk: unmapped: gh is not mapped. Stop and ask the user."
	fail_line LENDK_PROMPT=never -- usage "bad"
	assert_eq "$stderr" "lendk: usage: bad. See: lendk --help"
}

@test "FR19: interactive FIXes name the command, key, path and entry prefix" {
	fail_line LENDK_PROMPT=allow -- unmapped "gh is not mapped" CMD=gh
	assert_eq "$stderr" "lendk: unmapped: gh is not mapped. Map it: lendk add gh KEY..., or name keys: lendk run KEY... -- gh"
	fail_line LENDK_PROMPT=allow -- unsafe "/m is writable by others" PATH=/m
	assert_eq "$stderr" "lendk: unsafe: /m is writable by others. Fix it: chmod go-w /m, or recreate it as your own"
	fail_line LENDK_PROMPT=allow -- missing-key:empty "env/K has an empty first line" KEY=K
	assert_eq "$stderr" "lendk: missing-key: env/K has an empty first line. Set it: pass edit env/K"
	LENDK=$SB/bin/lendk-fn LENDK_PROMPT=allow LENDK_PREFIX=api run_lendk eval 'load_env; fail missing-key "api/K is not in the store" KEY=K'
	assert_eq "$stderr" "lendk: missing-key: api/K is not in the store. Add it: pass insert api/K"
	assert_class missing-key 125
}

@test "FR19: without LENDK_PROMPT, a call with no terminal gets the non-interactive FIX" {
	fail_line -- map "m:1: bad line"
	assert_eq "$stderr" "lendk: map: m:1: bad line. Stop and ask the user."
	assert_class map 125
}

@test "FR19: a substituted value is never rewritten again, by the prefix or by another token" {
	LENDK=$SB/bin/lendk-fn LENDK_PROMPT=allow LENDK_PREFIX=api run_lendk eval 'load_env; fail unsafe "p is writable by others" PATH=/home/alice/.env/KEY'
	assert_eq "$stderr" "lendk: unsafe: p is writable by others. Fix it: chmod go-w /home/alice/.env/KEY, or recreate it as your own"
}
