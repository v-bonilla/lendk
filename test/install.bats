#!/usr/bin/env bats
# PRD section 9: make install renames a fresh file into place, make uninstall keeps the map.
# shellcheck disable=SC2012,SC2016,SC2088

setup() {
	load helpers/common
	sandbox
	require make
	export LEND_SHIMS=$SB/shims
}

# mk ARG...: make in the repository; status and output as run gives them.
mk() { run make -s -C "$ROOT" "$@"; }

inode() { ls -i "$1" | awk '{ print $1 }'; }

@test "install: copies bin/lend to PREFIX/bin with mode 0755 and nothing else" {
	mk install PREFIX="$SB/p"
	assert_eq "$status" 0
	cmp "$LEND" "$SB/p/bin/lend"
	assert_eq "$(ls -ln "$SB/p/bin/lend" | cut -c1-10)" -rwxr-xr-x
	assert_eq "$(ls -A "$SB/p/bin")" lend
}

@test "install: a second install gives the file a new inode, and an open copy keeps its old file" {
	local before fd
	mk install PREFIX="$SB/p"
	before=$(inode "$SB/p/bin/lend")
	exec {fd}<"$SB/p/bin/lend"
	mk install PREFIX="$SB/p"
	assert_eq "$status" 0
	[[ $(inode "$SB/p/bin/lend") != "$before" ]]
	cmp - "$LEND" <&"$fd"
	exec {fd}<&-
	assert_eq "$(ls -A "$SB/p/bin")" lend
}

@test "install: DESTDIR prefixes the target" {
	mk install DESTDIR="$SB/d" PREFIX=/usr/local
	assert_eq "$status" 0
	cmp "$LEND" "$SB/d/usr/local/bin/lend"
}

@test "install: a relative PREFIX is rejected before anything is written" {
	mk install PREFIX='~/.local'
	assert_eq "$status" 2
	assert_line "$output" 'PREFIX must be an absolute path, for example PREFIX="$HOME/.local"'
	[[ ! -e "$ROOT/~" ]]
}

@test "uninstall: removes marker-bearing shims, the empty shim directory and lend, never the map" {
	mk install PREFIX="$SB/p"
	ln -s "$FIXTURES/stub-target" "$SB/bin/gh"
	"$SB/p/bin/lend" add gh GH_TOKEN >/dev/null 2>&1
	[[ -f $LEND_SHIMS/gh ]]
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 0
	[[ ! -e $LEND_SHIMS && ! -e $SB/p/bin/lend ]]
	assert_eq "$(<"$HOME/.config/lend/map")" 'gh GH_TOKEN'
}

@test "uninstall: keeps a foreign file and the shim directory holding it" {
	mkdir -m 700 "$LEND_SHIMS"
	printf '#!/bin/sh\necho mine\n' >"$LEND_SHIMS/tool"
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 0
	assert_eq "$(ls -A "$LEND_SHIMS")" tool
}

@test "uninstall: leaves a foreign lend in PREFIX/bin and says so" {
	mkdir -p "$SB/p/bin"
	printf '#!/bin/sh\necho other\n' >"$SB/p/bin/lend"
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 2
	assert_line "$output" "$SB/p/bin/lend is not a file make install wrote, so it stays"
	assert_eq "$(cat "$SB/p/bin/lend")" $'#!/bin/sh\necho other'
}

@test "uninstall: removes the default data directory only when empty" {
	unset LEND_SHIMS
	mk install PREFIX="$SB/p"
	ln -s "$FIXTURES/stub-target" "$SB/bin/gh"
	"$SB/p/bin/lend" add gh GH_TOKEN >/dev/null 2>&1
	[[ -f $HOME/.local/share/lend/shims/gh ]]
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 0
	[[ ! -e $HOME/.local/share/lend && -d $HOME/.local/share ]]
	mkdir -p "$HOME/.local/share/lend/shims" && touch "$HOME/.local/share/lend/other"
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 0
	assert_eq "$(ls -A "$HOME/.local/share/lend")" other
}
