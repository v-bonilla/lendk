#!/usr/bin/env bats
# AC4: a fresh HOME with Debian's skel files, the PRD 4.4 quick start, the PRD 4.3 blocks, then the key
# reaching gh from every kind of caller, and make uninstall leaving only the map.
# shellcheck disable=SC2016,SC2088

setup() {
	load helpers/common
	load helpers/pty
	sandbox
	require git
	require make
	local g
	# ~/bin, which the skel profile puts on PATH after /etc/profile resets it: gh, pass and gpg
	# stand-ins, and an outer command calling gh.
	SYS=$HOME/bin
	mkdir -p "$SYS" "$SB/other" "$SB/src/bin"
	ln -s "$FIXTURES/stub-target" "$SYS/gh"
	ln -s "$FIXTURES/stub-target" "$SB/other/gh"
	ln -s "$FIXTURES/fake-pass" "$SYS/pass"
	for g in gpg gpg2; do
		printf '#!/bin/sh\necho "gpg (GnuPG) 2.4.4"\n' >"$SYS/$g"
		chmod +x "$SYS/$g"
	done
	printf '#!/bin/sh\nexec gh "$@"\n' >"$SYS/outer"
	chmod +x "$SYS/outer"
	skel_profile >"$HOME/.profile"
	cp "$FIXTURES/bashrc" "$HOME/.bashrc"
	LOGIN_PATH=$SYS:${BASH%/*}:/usr/bin:/bin
	# The clone source: a scratch repository holding the working tree's install inputs.
	cp "$ROOT/Makefile" "$ROOT/LICENSE" "$SB/src/"
	cp "$LENDK" "$SB/src/bin/"
	git -C "$SB/src" init -q
	git -C "$SB/src" add -A
	git -C "$SB/src" -c user.name=test -c user.email=test commit -qm src
	quickstart
}

# login_env CMD...: CMD in $HOME in an environment built from scratch, as a login would start it.
login_env() {
	(cd "$HOME" && env -i HOME="$HOME" PATH="$LOGIN_PATH" TERM=dumb STUB_LOG="$STUB_LOG" \
		PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" "$@")
}

# quickstart: PRD 4.4's five commands with a local clone source and the store entry written for the
# fake pass; command 3 starts the login shells that run commands 4 and 5. Then the other 4.3 blocks.
quickstart() {
	login_env bash -c "git clone -q $(printf %q "$SB/src") lendk && make -s -C lendk install"
	login_env bash -c '~/.local/bin/lendk init sh >> ~/.profile'
	printf '%s\n' "$SENTINEL" >"$SB/store/env/GH_TOKEN.gpg"
	login_env bash -lc 'lendk add gh GH_TOKEN' >/dev/null
	login_env bash -lc 'lendk add outer GH_TOKEN' >/dev/null
	login_env bash -lc 'lendk init sh >> ~/.zshenv && lendk init bash >> ~/.bashrc'
	mkdir -p "$HOME/.config/environment.d"
	login_env bash -lc 'lendk init systemd > ~/.config/environment.d/99-lendk.conf'
	rm -rf "$SB"/log/pass.* "$SB"/log/target.*
}

# token: the GH_TOKEN the one gh call received, or "none"; fails unless gh ran exactly once.
token() {
	local logs=("$SB"/log/target.*) v
	assert_eq "${#logs[@]}" 1
	v=$(tr '\0' '\n' <"${logs[0]}/env" | sed -n 's/^GH_TOKEN=//p')
	printf '%s\n' "${v:-none}"
	rm -rf "${logs[0]}"
}

# decrypts: the number of backend calls so far.
decrypts() {
	local calls=("$SB"/log/pass.*)
	[[ -e ${calls[0]} ]] || calls=()
	printf '%s\n' "${#calls[@]}"
}

@test "AC4: the quick start installs lendk, writes the map and the shim, and the parent lacks GH_TOKEN" {
	[[ -x $HOME/.local/bin/lendk && -f $HOME/.local/share/lendk/shims/gh ]]
	assert_eq "$(<"$HOME/.config/lendk/map")" $'gh GH_TOKEN\nouter GH_TOKEN'
	run login_env bash -lc 'printf "%s|" "${GH_TOKEN-unset}"; command -v gh'
	assert_eq "$output" "unset|$HOME/.local/share/lendk/shims/gh"
}

@test "AC4: interactive bash in a terminal gets the key" {
	in_pty "$(printf '%q ' env -i HOME="$HOME" PATH="$LOGIN_PATH" TERM=dumb STUB_LOG="$STUB_LOG" \
		PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" bash -li -c 'gh; exit $?')"
	assert_eq "$status" 0
	assert_eq "$(token)" "$SENTINEL"
}

@test "AC4: bash -lc gets the key" {
	login_env bash -lc gh
	assert_eq "$(token)" "$SENTINEL"
}

@test "AC4: zsh -c under a parent that prepended another gh gets the key" {
	require zsh
	LOGIN_PATH=$SB/other:$LOGIN_PATH login_env zsh -c gh
	assert_eq "$(token)" "$SENTINEL"
}

@test "AC4: Python subprocess without a shell, started from sh -lc like a desktop session, gets the key" {
	require python3
	login_env sh -lc 'exec python3 -c "import subprocess; subprocess.run([\"gh\"], check=True)"'
	assert_eq "$(token)" "$SENTINEL"
}

@test "AC4: a nested shim reuses the key with one decrypt" {
	login_env bash -lc outer
	assert_eq "$(token)" "$SENTINEL"
	assert_eq "$(decrypts)" 1
}

@test "AC4: systemd's environment.d generator puts the shim directory first" {
	require environment-d
	run env -i HOME="$HOME" PATH=/usr/bin:/bin /usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator
	[[ $'\n'$output == *$'\n'"PATH=$HOME/.local/share/lendk/shims:"* ]]
}

@test "AC4: removing the blocks and make uninstall leave only the map" {
	local f
	for f in .profile .zshenv .bashrc; do
		sed '/^# >>> lendk >>>$/,/^# <<< lendk <<<$/d' "$HOME/$f" >"$SB/rc" && cat "$SB/rc" >"$HOME/$f"
	done
	rm "$HOME/.config/environment.d/99-lendk.conf"
	login_env make -s -C lendk uninstall
	skel_profile | cmp - "$HOME/.profile"
	cmp "$FIXTURES/bashrc" "$HOME/.bashrc"
	[[ ! -s $HOME/.zshenv ]]
	run find "$HOME" \( -path "$HOME/lendk" -o -path "$SYS" \) -prune -o \( -type f -o -type l \) -print
	assert_eq "$(sort <<<"$output")" "$(printf '%s\n' "$HOME/.bashrc" "$HOME/.config/lendk/map" "$HOME/.profile" "$HOME/.zshenv")"
	[[ ! -e $HOME/.local/share/lendk/shims ]]
}
