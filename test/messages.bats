#!/usr/bin/env bats
# Every class line fail prints follows the message contract in both modes; run_lendk checks each line.
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

# bats test_tags=unit
@test "every class gives one contract line and its exit hint, in both modes" {
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

# map LINE...: write a private map at the default path.
map() {
	mkdir -p "$HOME/.config/lendk" && chmod 700 "$HOME/.config/lendk"
	printf '%s\n' "$@" >"$HOME/.config/lendk/map"
	chmod 600 "$HOME/.config/lendk/map"
}

@test "non-interactive FIXes hand the step to the user, or point to lendk --help" {
	map 'stub K' 'nothere K'
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	: >"$SB/store/env/K.gpg"
	echo locked >"$SB/store/env/K.mode"
	LENDK_PROMPT=never run_lendk run -- stub
	assert_eq "$stderr" "lendk: locked: env/K needs the gpg passphrase and this call cannot prompt. Ask the user to run 'lendk unlock K' in a terminal, then retry."
	rm "$SB/store/env/K.mode"
	store_entry K value
	LENDK_PROMPT=never LENDK_SHIMS=$SB/s run_lendk run -- nothere
	assert_eq "$stderr" "lendk: not-found: nothere is not on PATH outside $SB/s. Install nothere, or ask the user."
	LENDK_PROMPT=never run_lendk run -- other
	assert_eq "$stderr" "lendk: unmapped: other is not mapped. Stop and ask the user."
	LENDK_PROMPT=never run_lendk frobnicate
	assert_eq "$stderr" "lendk: usage: unknown verb 'frobnicate'. See: lendk --help"
}

@test "interactive FIXes name the command, key, path and entry prefix" {
	map 'stub K'
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	LENDK_PROMPT=allow run_lendk run -- nothere
	assert_eq "$stderr" "lendk: unmapped: nothere is not mapped. Map it: lendk add nothere KEY..., or name keys: lendk run KEY... -- nothere"
	LENDK_PROMPT=allow LENDK_PREFIX=api run_lendk run -- stub
	assert_eq "$stderr" "lendk: missing-key: api/K is not in the store. Add it: pass insert api/K"
	assert_class missing-key 125
	store_entry K
	LENDK_PROMPT=allow run_lendk run -- stub
	assert_eq "$stderr" "lendk: missing-key: env/K has an empty first line. Set it: pass edit env/K"
	chmod o+w "$HOME/.config/lendk"
	LENDK_PROMPT=allow run_lendk run -- stub
	assert_eq "$stderr" "lendk: unsafe: $HOME/.config/lendk is writable by others. Fix it: chmod go-w $HOME/.config/lendk, or recreate it as your own"
}

@test "without LENDK_PROMPT, a call with no terminal gets the non-interactive FIX" {
	map 'stub K 1BAD'
	run_lendk run -- stub
	assert_eq "$stderr" "lendk: map: $HOME/.config/lendk/map:1: '1BAD' is not a valid key name. Stop and ask the user."
	assert_class map 125
}

@test "a substituted value is never rewritten again, by the prefix or by another token" {
	local dir=$HOME/.env/KEY
	mkdir -p "$dir"
	printf 'stub K\n' >"$dir/map"
	chmod 600 "$dir/map"
	chmod 777 "$dir"
	LENDK_MAP=$dir/map LENDK_PROMPT=allow LENDK_PREFIX=api run_lendk run -- stub
	assert_eq "$stderr" "lendk: unsafe: $dir is writable by others. Fix it: chmod go-w $dir, or recreate it as your own"
}
