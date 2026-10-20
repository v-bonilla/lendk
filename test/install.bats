#!/usr/bin/env bats
# make install builds the binary and renames it into place, make uninstall keeps the map.
# shellcheck disable=SC2012,SC2016,SC2088

setup() {
	load helpers/common
	sandbox
	require make
	cargo_env
	export LENDK_SHIMS=$SB/shims
	BUILT=$CARGO_TARGET_DIR/$(built)
}

# built: the release binary's path under the build directory, as the Makefile names it.
built() {
	if [[ $(uname -s) == Linux ]]; then
		echo "$(uname -m)-unknown-linux-musl/release/lendk"
	else
		echo "$(rustc -vV | sed -n 's/^host: //p')/release/lendk"
	fi
}

# mk ARG...: make in the repository; status and output as run gives them.
mk() { run make -s -C "$ROOT" "$@"; }

inode() { ls -i "$1" | awk '{ print $1 }'; }

@test "install: builds the release binary and copies it to PREFIX/bin with mode 0755 and nothing else" {
	mk install PREFIX="$SB/p"
	assert_eq "$status" 0
	cmp "$BUILT" "$SB/p/bin/lendk"
	assert_eq "$("$SB/p/bin/lendk" --version)" "$("$LENDK" --version)"
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
	cmp - "$BUILT" <&"$fd"
	exec {fd}<&-
	assert_eq "$(ls -A "$SB/p/bin")" lendk
}

@test "install: DESTDIR prefixes the target" {
	mk install DESTDIR="$SB/d" PREFIX=/usr/local
	assert_eq "$status" 0
	cmp "$BUILT" "$SB/d/usr/local/bin/lendk"
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

@test "uninstall: leaves a foreign lendk in PREFIX/bin and says so, never running it" {
	mkdir -p "$SB/p/bin"
	printf '#!/bin/sh\ntouch %q\necho "lendk 1.1.0"\n' "$SB/ran" >"$SB/p/bin/lendk"
	chmod 755 "$SB/p/bin/lendk"
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 2
	assert_line "$output" "$SB/p/bin/lendk is not a file make install wrote, so it stays"
	[[ -f $SB/p/bin/lendk && ! -e $SB/ran ]]
}

@test "uninstall: removes a regular file holding the binary's marker or 1.x's second line, never a link to one" {
	mkdir -p "$SB/p/bin"
	cp "$LENDK" "$SB/p/bin/lendk"
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 0
	[[ ! -e $SB/p/bin/lendk ]]
	cp "$FIXTURES/lendk-1.x" "$SB/p/bin/lendk"
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 0
	[[ ! -e $SB/p/bin/lendk ]]
	ln -s "$LENDK" "$SB/p/bin/lendk"
	mk uninstall PREFIX="$SB/p"
	assert_eq "$status" 2
	[[ -L $SB/p/bin/lendk ]]
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
