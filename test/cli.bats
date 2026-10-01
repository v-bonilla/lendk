#!/usr/bin/env bats
# CLI surface: --help, --version, usage errors, inherited functions, section 8 settings.

setup() {
	load helpers/common
	sandbox
}

# settings: print map, shims, store, prefix and timeout as load_env sets them.
settings() {
	# shellcheck disable=SC2016
	LENDK=$SB/bin/lendk-fn run_lendk eval 'load_env; printf "%s\n" "$map" "$shims" "$store" "$prefix" "$timeout"'
}

@test "FR36: --help prints the reference to stdout and exits 0" {
	run_lendk --help
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	assert_line "$output" "Usage:"
	assert_line "$output" "Environment:"
}

@test "FR36: --version prints lendk X.Y.Z" {
	run_lendk --version
	assert_eq "$status" 0
	[[ $output =~ ^lendk\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
	assert_eq "$stderr" ""
}

@test "FR36: no arguments, an unknown verb, or extra words after --help or --version are usage" {
	run_lendk
	assert_eq "$stderr" "lendk: usage: no verb given. See: lendk --help"
	assert_class usage 2
	assert_eq "$output" ""
	run_lendk frobnicate
	assert_eq "$stderr" "lendk: usage: unknown verb 'frobnicate'. See: lendk --help"
	assert_class usage 2
	run_lendk --help extra
	assert_class usage 2
	run_lendk --version extra
	assert_class usage 2
}

@test "FR9: exported functions named like commands and builtins leave --help and --version byte-identical" {
	local clean hijacked
	clean=$("$LENDK" --help; "$LENDK" --version)
	# shellcheck disable=SC2016
	hijacked=$(bash -c '
		for name in printf env mktemp pass sed cat unset set declare builtin read exit test [; do
			eval "$name() { echo hijacked-$name; }"
			export -f "${name?}"
		done
		"$0" --help
		"$0" --version' "$LENDK")
	assert_eq "$hijacked" "$clean"
}

@test "FR9: inherited functions are gone before any command runs" {
	lendk_probe() { echo inherited; }
	export -f lendk_probe
	run lendk-fn declare -F lendk_probe
	assert_eq "$status" 1
	assert_eq "$output" ""
}

@test "section 8: default paths follow HOME" {
	unset PASSWORD_STORE_DIR
	settings
	assert_eq "$stderr" ""
	assert_eq "$output" "$HOME/.config/lendk/map
$HOME/.local/share/lendk/shims
$HOME/.password-store
env
10"
}

@test "section 8: absolute XDG values move the defaults and relative ones are ignored" {
	unset PASSWORD_STORE_DIR
	XDG_CONFIG_HOME=/cfg XDG_DATA_HOME=/data settings
	assert_eq "$output" "/cfg/lendk/map
/data/lendk/shims
$HOME/.password-store
env
10"
	XDG_CONFIG_HOME=cfg XDG_DATA_HOME=./data settings
	assert_eq "$output" "$HOME/.config/lendk/map
$HOME/.local/share/lendk/shims
$HOME/.password-store
env
10"
}

@test "section 8: LENDK_MAP, LENDK_SHIMS, PASSWORD_STORE_DIR and LENDK_PREFIX override the defaults" {
	LENDK_MAP=/m/map LENDK_SHIMS=/s XDG_CONFIG_HOME=/cfg PASSWORD_STORE_DIR=/store LENDK_PREFIX=api settings
	assert_eq "$output" "/m/map
/s
/store
api
10"
}

@test "5.1: LENDK_PROMPT accepts auto, never and allow; allow makes the default timeout 60 s" {
	local value
	for value in auto never; do
		LENDK_PROMPT=$value settings
		assert_eq "${output##*$'\n'}" 10
	done
	LENDK_PROMPT=allow settings
	assert_eq "${output##*$'\n'}" 60
}

@test "5.1: any other LENDK_PROMPT is usage" {
	local value
	for value in yes '' ALLOW; do
		LENDK_PROMPT=$value settings
		assert_eq "$stderr" "lendk: usage: LENDK_PROMPT is '$value'; use auto, never or allow. See: lendk --help"
		assert_class usage 2
		assert_eq "$output" ""
	done
}

@test "section 8: LENDK_TIMEOUT accepts 1 to 3600 and applies to both modes" {
	local value
	for value in 1 3600; do
		LENDK_TIMEOUT=$value settings
		assert_eq "${output##*$'\n'}" "$value"
		LENDK_TIMEOUT=$value LENDK_PROMPT=allow settings
		assert_eq "${output##*$'\n'}" "$value"
	done
}

@test "section 8: any other LENDK_TIMEOUT is usage" {
	local value
	for value in 0 3601 05 1.5 -1 abc ''; do
		LENDK_TIMEOUT=$value settings
		assert_eq "$stderr" "lendk: usage: LENDK_TIMEOUT is '$value'; use whole seconds from 1 to 3600. See: lendk --help"
		assert_class usage 2
	done
}
