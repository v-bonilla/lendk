#!/usr/bin/env bats
# PRD 4.3: login shells, bash -lc and zsh -c reach the shims through the init blocks (FR35).

setup() {
	load helpers/common
	sandbox
	local g
	mkdir -p "$HOME/.local/bin" "$SB/other"
	ln -s "$FIXTURES/stub-target" "$HOME/.local/bin/gh"
	ln -s "$FIXTURES/stub-target" "$SB/other/gh"
	ln -s "$FIXTURES/fake-pass" "$HOME/.local/bin/pass"
	for g in gpg gpg2; do
		printf '#!/bin/sh\necho "gpg (GnuPG) 2.4.4"\n' >"$HOME/.local/bin/$g"
		chmod +x "$HOME/.local/bin/$g"
	done
	skel_profile >"$HOME/.profile"
	cp "$FIXTURES/bashrc" "$HOME/.bashrc"
	printf '%s\n' "$SENTINEL" >"$SB/store/env/GH_TOKEN.gpg"
	run_lendk add gh GH_TOKEN
	assert_eq "$status" 0
}

# login_env CMD...: CMD in an environment built from scratch, as a login would start it.
login_env() {
	env -i HOME="$HOME" PATH="${BASH%/*}:/usr/bin:/bin" TERM=dumb STUB_LOG="$STUB_LOG" PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" "$@"
}

# token: the GH_TOKEN the one gh call received, or "none"; fails unless gh ran exactly once.
token() {
	local logs=("$SB"/log/target.*) v
	assert_eq "${#logs[@]}" 1
	v=$(tr '\0' '\n' <"${logs[0]}/env" | sed -n 's/^GH_TOKEN=//p')
	printf "%s\n" "${v:-none}"
	rm -rf "${logs[0]}"
}

@test "FR35: bash -lc with the skel profile reaches the shim once init sh is appended" {
	login_env bash -lc 'gh'
	assert_eq "$(token)" none
	run_lendk init sh
	printf '%s\n' "$output" >>"$HOME/.profile"
	login_env bash -lc 'gh'
	assert_eq "$(token)" "$SENTINEL"
}

@test "FR35: zsh -c behind a prepended gh reaches the shim through ~/.zshenv" {
	require zsh
	run_lendk init sh
	printf '%s\n' "$output" >"$HOME/.zshenv"
	env -i HOME="$HOME" PATH="$SB/other:$HOME/.local/bin:${BASH%/*}:/usr/bin:/bin" STUB_LOG="$STUB_LOG" \
		PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" zsh -c 'gh'
	assert_eq "$(token)" "$SENTINEL"
}
