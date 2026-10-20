#!/usr/bin/env bats
# CLI surface: --help, --version, usage errors, inherited functions, environment settings.
# shellcheck disable=SC2030,SC2031

setup() {
	load helpers/common
	sandbox
}

# settings: print the timeout load_env sets; no verb shows it short of waiting it out.
settings() {
	# shellcheck disable=SC2016
	LENDK=$SB/bin/lendk-fn run_lendk eval 'load_env; printf "%s\n" "$timeout"'
}

# lends_at MAP SHIMS STORE PREFIX: add writes the map at MAP and the shim in SHIMS, and run gives the
# target the key from STORE/PREFIX/K1.
lends_at() {
	ln -sf "$FIXTURES/stub-target" "$SB/bin/stub"
	rm -rf "$SB/log" && mkdir "$SB/log"
	run_lendk add stub K1
	assert_eq "$status" 0
	[[ -f $1 && -x $2/stub ]] || { echo "no map at $1 or shim at $2/stub" >&2; return 1; }
	mkdir -p "$3/$4"
	printf 'value-%s\n' "$SENTINEL" >"$3/$4/K1.gpg"
	run_lendk run -- stub
	assert_eq "$stderr" ""
	assert_eq "$status" 0
	local logs=("$SB"/log/target.*)
	tr '\0' '\n' <"${logs[0]}/env" | grep -qx "K1=value-$SENTINEL"
	rm -rf "$1" "$2" "$3/$4/K1.gpg"
}

@test "--help prints the reference to stdout and exits 0" {
	run_lendk --help
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	assert_line "$output" "Usage:"
	assert_line "$output" "Environment:"
}

@test "--version prints lendk X.Y.Z" {
	run_lendk --version
	assert_eq "$status" 0
	[[ $output =~ ^lendk\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
	assert_eq "$stderr" ""
}

@test "no arguments, an unknown verb, or extra words after --help or --version are usage" {
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

# bats test_tags=port:retire
@test "exported functions named like commands and builtins leave --help and --version byte-identical" {
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

# bats test_tags=port:unit
@test "inherited functions are gone before any command runs" {
	lendk_probe() { echo inherited; }
	export -f lendk_probe
	run lendk-fn declare -F lendk_probe
	assert_eq "$status" 1
	assert_eq "$output" ""
}

@test "default paths follow HOME" {
	unset PASSWORD_STORE_DIR
	lends_at "$HOME/.config/lendk/map" "$HOME/.local/share/lendk/shims" "$HOME/.password-store" env
}

@test "absolute XDG values move the defaults and relative ones are ignored" {
	unset PASSWORD_STORE_DIR
	XDG_CONFIG_HOME=$SB/cfg XDG_DATA_HOME=$SB/data lends_at "$SB/cfg/lendk/map" "$SB/data/lendk/shims" "$HOME/.password-store" env
	XDG_CONFIG_HOME=cfg XDG_DATA_HOME=./data lends_at "$HOME/.config/lendk/map" "$HOME/.local/share/lendk/shims" "$HOME/.password-store" env
}

@test "LENDK_MAP, LENDK_SHIMS, PASSWORD_STORE_DIR and LENDK_PREFIX override the defaults" {
	LENDK_MAP=$SB/m/map LENDK_SHIMS=$SB/s XDG_CONFIG_HOME=$SB/cfg PASSWORD_STORE_DIR=$SB/store2 LENDK_PREFIX=api \
		lends_at "$SB/m/map" "$SB/s" "$SB/store2" api
}

# timeout_line: lendk run of a mapped key whose backend hangs; the timeout line names the bound.
timeout_line() {
	ln -sf "$FIXTURES/stub-target" "$SB/bin/stub"
	export LENDK_SHIMS=$SB/shims
	mkdir -p "$HOME/.config/lendk" && chmod 700 "$HOME/.config/lendk"
	printf 'stub K1\n' >"$HOME/.config/lendk/map"
	chmod 600 "$HOME/.config/lendk/map"
	: >"$SB/store/env/K1.gpg"
	echo hang >"$SB/store/env/K1.mode"
	run_lendk run -- stub
	assert_class timeout 120
	[[ $stderr == "lendk: timeout: env/K1: gpg did not finish within $1 s. "* ]]
}

@test "LENDK_PROMPT accepts auto, never and allow" {
	local value
	for value in auto never allow; do
		LENDK_PROMPT=$value run_lendk sync
		assert_eq "$status" 0
		assert_eq "$stderr" ""
	done
}

# bats test_tags=port:unit
@test "the default LENDK_TIMEOUT is 60 s with LENDK_PROMPT=allow and 10 s otherwise" {
	local value
	for value in auto never; do
		LENDK_PROMPT=$value settings
		assert_eq "$output" 10
	done
	LENDK_PROMPT=allow settings
	assert_eq "$output" 60
	LENDK_TIMEOUT=3600 settings
	assert_eq "$output" 3600
}

@test "any other LENDK_PROMPT is usage" {
	local value
	for value in yes '' ALLOW; do
		LENDK_PROMPT=$value run_lendk sync
		assert_eq "$stderr" "lendk: usage: LENDK_PROMPT is '$value'; use auto, never or allow. See: lendk --help"
		assert_class usage 2
		assert_eq "$output" ""
	done
}

@test "LENDK_TIMEOUT accepts 1 to 3600 and applies to both modes" {
	LENDK_TIMEOUT=1 timeout_line 1
	LENDK_TIMEOUT=1 LENDK_PROMPT=allow timeout_line 1
	LENDK_TIMEOUT=3600 run_lendk sync
	assert_eq "$status" 0
	LENDK_TIMEOUT=3600 LENDK_PROMPT=allow run_lendk sync
	assert_eq "$status" 0
}

@test "any other LENDK_TIMEOUT is usage" {
	local value
	for value in 0 3601 05 1.5 -1 abc ''; do
		LENDK_TIMEOUT=$value run_lendk sync
		assert_eq "$stderr" "lendk: usage: LENDK_TIMEOUT is '$value'; use whole seconds from 1 to 3600. See: lendk --help"
		assert_class usage 2
	done
}
