#!/usr/bin/env bats
# FR8: the backend runs under an environment built from scratch, directly and under a nested shim.
# shellcheck disable=SC2016,SC2030,SC2031,SC2329

setup() {
	load helpers/common
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	export LEND_SHIMS=$SB/shims
	mkdir -p "$LEND_SHIMS" && chmod 700 "$LEND_SHIMS"
	mkdir -p "$HOME/.config/lend" && chmod 700 "$HOME/.config/lend"
	printf '%s\n' 'outer K1' 'stub K2' >"$HOME/.config/lend/map"
	chmod 600 "$HOME/.config/lend/map"
	printf '%s\n' "$SENTINEL-1" >"$SB/store/env/K1.gpg"
	printf '%s\n' "$SENTINEL-2" >"$SB/store/env/K2.gpg"
	printf '#!/bin/sh\nexec %q run -- stub\n' "$LEND" >"$SB/bin/outer"
	chmod 755 "$SB/bin/outer"
	# The caller's environment: allowed names, a key, exported functions, BASH_ENV, ENV and strays.
	export GNUPGHOME=$SB/gnupg PINENTRY_USER_DATA=pud GPG_TTY=/dev/null LC_ALL=C XDG_RUNTIME_DIR=$SB/run \
		DISPLAY=:9 PASSWORD_STORE_GPG_OPTS=--opt PASSWORD_STORE_X=x BASH_ENV=$SB/bash_env ENV=$SB/env \
		STRAY=stray OTHER_KEY=other LEND_INJECTED=OTHER_KEY XDG_CONFIG_HOME=$HOME/.config
	: >"$SB/bash_env"
	: >"$SB/env"
	pass() { :; }
	export -f pass
	PATH=$LEND_SHIMS:$PATH
}

ALLOWED='^(PATH|HOME|USER|LOGNAME|LANG|LC_[A-Z_]+|TERM|TMPDIR|DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR|GNUPGHOME|PINENTRY_USER_DATA|GPG_TTY|PASSWORD_STORE_[A-Z_]+|PWD|SHLVL|_)$'

# check_pass_env LOG: LOG's environment holds only allowed names, the caller's values for the set
# ones, and a PATH without the shim directory.
check_pass_env() {
	local e n names=()
	while IFS= read -r -d '' e; do
		n=${e%%=*}
		[[ $n =~ $ALLOWED ]] || { echo "not allowed in the backend: $n" >&2; return 1; }
		names+=("$n")
		[[ $e != *"$SENTINEL"* ]] || { echo "value in the backend: $n" >&2; return 1; }
		[[ $n != PATH ]] || [[ :${e#*=}: != *":$LEND_SHIMS:"* ]] || { echo "shims on the backend PATH" >&2; return 1; }
	done <"$1/env"
	for n in HOME GNUPGHOME PINENTRY_USER_DATA GPG_TTY LC_ALL XDG_RUNTIME_DIR DISPLAY TMPDIR \
		PASSWORD_STORE_DIR PASSWORD_STORE_GPG_OPTS PASSWORD_STORE_X; do
		tr '\0' '\n' <"$1/env" | grep -qxF -- "$n=${!n}" || { echo "missing in the backend: $n" >&2; return 1; }
	done
}

@test "FR8: a direct call's backend gets only the allowlisted environment" {
	run_lend run -- stub
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	local logs=("$SB"/log/pass.*)
	assert_eq "${#logs[@]}" 1
	check_pass_env "${logs[0]}"
}

@test "FR8: under a nested shim, the inner backend sees neither the outer key nor the caller's" {
	run_lend run -- outer
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	local logs=("$SB"/log/pass.*) log
	assert_eq "${#logs[@]}" 2
	for log in "${logs[@]}"; do check_pass_env "$log"; done
	local target=("$SB"/log/target.*)
	tr '\0' '\n' <"${target[0]}/env" | grep -qxF "K1=$SENTINEL-1"
	tr '\0' '\n' <"${target[0]}/env" | grep -qxF "K2=$SENTINEL-2"
	tr '\0' '\n' <"${target[0]}/env" | grep -qx 'LEND_INJECTED=OTHER_KEY K1 K2'
}
