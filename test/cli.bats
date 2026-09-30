#!/usr/bin/env bats
# CLI surface: --help, --version, usage errors, inherited functions, section 8 settings.

setup() {
	load helpers/common
	sandbox
}

# settings: print map, shims, store, prefix and timeout as load_env sets them.
settings() {
	# shellcheck disable=SC2016
	LEND=$SB/bin/lend-fn run_lend eval 'load_env; printf "%s\n" "$map" "$shims" "$store" "$prefix" "$timeout"'
}

@test "FR36: --help prints the reference to stdout and exits 0" {
	run_lend --help
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	assert_line "$output" "Usage:"
	assert_line "$output" "Environment:"
}

@test "FR36: --version prints lend X.Y.Z" {
	run_lend --version
	assert_eq "$status" 0
	[[ $output =~ ^lend\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
	assert_eq "$stderr" ""
}

@test "FR36: no arguments, an unknown verb, or extra words after --help or --version are usage" {
	run_lend
	assert_eq "$stderr" "lend: usage: no verb given. See: lend --help"
	assert_class usage 2
	assert_eq "$output" ""
	run_lend frobnicate
	assert_eq "$stderr" "lend: usage: unknown verb 'frobnicate'. See: lend --help"
	assert_class usage 2
	run_lend --help extra
	assert_class usage 2
	run_lend --version extra
	assert_class usage 2
}

@test "FR9: exported functions named like commands and builtins leave --help and --version byte-identical" {
	local clean hijacked
	clean=$("$LEND" --help; "$LEND" --version)
	# shellcheck disable=SC2016
	hijacked=$(bash -c '
		for name in printf env mktemp pass sed cat unset set declare builtin read exit test [; do
			eval "$name() { echo hijacked-$name; }"
			export -f "${name?}"
		done
		"$0" --help
		"$0" --version' "$LEND")
	assert_eq "$hijacked" "$clean"
}

@test "FR9: inherited functions are gone before any command runs" {
	lend_probe() { echo inherited; }
	export -f lend_probe
	run lend-fn declare -F lend_probe
	assert_eq "$status" 1
	assert_eq "$output" ""
}

@test "section 8: default paths follow HOME" {
	unset PASSWORD_STORE_DIR
	settings
	assert_eq "$stderr" ""
	assert_eq "$output" "$HOME/.config/lend/map
$HOME/.local/share/lend/shims
$HOME/.password-store
env
10"
}

@test "section 8: absolute XDG values move the defaults and relative ones are ignored" {
	unset PASSWORD_STORE_DIR
	XDG_CONFIG_HOME=/cfg XDG_DATA_HOME=/data settings
	assert_eq "$output" "/cfg/lend/map
/data/lend/shims
$HOME/.password-store
env
10"
	XDG_CONFIG_HOME=cfg XDG_DATA_HOME=./data settings
	assert_eq "$output" "$HOME/.config/lend/map
$HOME/.local/share/lend/shims
$HOME/.password-store
env
10"
}

@test "section 8: LEND_MAP, LEND_SHIMS, PASSWORD_STORE_DIR and LEND_PREFIX override the defaults" {
	LEND_MAP=/m/map LEND_SHIMS=/s XDG_CONFIG_HOME=/cfg PASSWORD_STORE_DIR=/store LEND_PREFIX=api settings
	assert_eq "$output" "/m/map
/s
/store
api
10"
}

@test "5.1: LEND_PROMPT accepts auto, never and allow; allow makes the default timeout 60 s" {
	local value
	for value in auto never; do
		LEND_PROMPT=$value settings
		assert_eq "${output##*$'\n'}" 10
	done
	LEND_PROMPT=allow settings
	assert_eq "${output##*$'\n'}" 60
}

@test "5.1: any other LEND_PROMPT is usage" {
	local value
	for value in yes '' ALLOW; do
		LEND_PROMPT=$value settings
		assert_eq "$stderr" "lend: usage: LEND_PROMPT is '$value'; use auto, never or allow. See: lend --help"
		assert_class usage 2
		assert_eq "$output" ""
	done
}

@test "section 8: LEND_TIMEOUT accepts 1 to 3600 and applies to both modes" {
	local value
	for value in 1 3600; do
		LEND_TIMEOUT=$value settings
		assert_eq "${output##*$'\n'}" "$value"
		LEND_TIMEOUT=$value LEND_PROMPT=allow settings
		assert_eq "${output##*$'\n'}" "$value"
	done
}

@test "section 8: any other LEND_TIMEOUT is usage" {
	local value
	for value in 0 3601 05 1.5 -1 abc ''; do
		LEND_TIMEOUT=$value settings
		assert_eq "$stderr" "lend: usage: LEND_TIMEOUT is '$value'; use whole seconds from 1 to 3600. See: lend --help"
		assert_class usage 2
	done
}
