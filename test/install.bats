#!/usr/bin/env bats
# PRD section 9: make install renames a fresh file into place, make uninstall keeps the map.
# shellcheck disable=SC2012,SC2016,SC2088

setup() {
	load helpers/common
	sandbox
	require make
	export LENDK_SHIMS=$SB/shims
}

# mk ARG...: make in the repository; status and output as run gives them.
mk() { run make -s -C "$ROOT" "$@"; }

inode() { ls -i "$1" | awk '{ print $1 }'; }

@test "install: copies bin/lendk to PREFIX/bin with mode 0755 and nothing else" {
	mk install PREFIX="$SB/p"
	assert_eq "$status" 0
	cmp "$LENDK" "$SB/p/bin/lendk"
	assert_eq "$(ls -ln "$SB/p/bin/lendk" | cut -c1-10)" -rwxr-xr-x
	assert_eq "$(ls -A "$SB/p/bin")" lendk
}

@test "install: a second install gives the file a new inode, and an open copy keeps its old file" {
	local before fd
	mk install PREFIX="$SB/p"
	before=$(inode "$SB/p/bin/lendk")
	exec {fd}<"$SB/p/bin/lendk"
	mk install PREFIX="$SB/p"
	assert_eq "$status" 0
	[[ $(inode "$SB/p/bin/lendk") != "$before" ]]
	cmp - "$LENDK" <&"$fd"
	exec {fd}<&-
	assert_eq "$(ls -A "$SB/p/bin")" lendk
}

@test "install: DESTDIR prefixes the target" {
	mk install DESTDIR="$SB/d" PREFIX=/usr/local
	assert_eq "$status" 0
	cmp "$LENDK" "$SB/d/usr/local/bin/lendk"
}

@test "install: a relative PREFIX is rejected before anything is written" {
	mk install PREFIX='~/.local'
	assert_eq "$status" 2
	assert_line "$output" 'PREFIX must be an absolute path, for example PREFIX="$HOME/.local"'
	[[ ! -e "$ROOT/~" ]]
}

@test "uninstall: removes marker-bearing shims, the empty shim directory and lendk, never the map" {
	mk install PREFIX="$SB/p"
	ln -s "$FIXTURES/stub-target" "$SB/bin/gh"
	"$SB/p/bin/lendk" add gh GH_TOKEN >/dev/null 2>&1
	[[ -f $LENDK_SHIMS/gh ]]
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 0
	[[ ! -e $LENDK_SHIMS && ! -e $SB/p/bin/lendk ]]
	assert_eq "$(<"$HOME/.config/lendk/map")" 'gh GH_TOKEN'
}

@test "uninstall: keeps a foreign file and the shim directory holding it" {
	mkdir -m 700 "$LENDK_SHIMS"
	printf '#!/bin/sh\necho mine\n' >"$LENDK_SHIMS/tool"
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 0
	assert_eq "$(ls -A "$LENDK_SHIMS")" tool
}

@test "uninstall: leaves a foreign lendk in PREFIX/bin and says so" {
	mkdir -p "$SB/p/bin"
	printf '#!/bin/sh\necho other\n' >"$SB/p/bin/lendk"
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 2
	assert_line "$output" "$SB/p/bin/lendk is not a file make install wrote, so it stays"
	assert_eq "$(cat "$SB/p/bin/lendk")" $'#!/bin/sh\necho other'
}

@test "uninstall: removes the default data directory only when empty" {
	unset LENDK_SHIMS
	mk install PREFIX="$SB/p"
	ln -s "$FIXTURES/stub-target" "$SB/bin/gh"
	"$SB/p/bin/lendk" add gh GH_TOKEN >/dev/null 2>&1
	[[ -f $HOME/.local/share/lendk/shims/gh ]]
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 0
	[[ ! -e $HOME/.local/share/lendk && -d $HOME/.local/share ]]
	mkdir -p "$HOME/.local/share/lendk/shims" && touch "$HOME/.local/share/lendk/other"
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 0
	assert_eq "$(ls -A "$HOME/.local/share/lendk")" other
}
