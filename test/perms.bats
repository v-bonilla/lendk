#!/usr/bin/env bats
# FR28 for run: the map and its directory must be the user's own and closed to others.

setup() {
	load helpers/common
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	export LENDK_SHIMS=$SB/shims K1=one
	DIR=$HOME/.config/lendk
	MAP=$DIR/map
	mkdir -p "$DIR" && chmod 700 "$DIR"
	printf 'stub K1\n' >"$MAP"
	chmod 600 "$MAP"
}

# refute_target: the target never ran.
refute_target() { assert_eq "$(compgen -G "$SB/log/target.*")" ""; }

@test "FR28: a private map in a private directory passes, also under umask 000" {
	umask 000
	run_lendk run -- stub
	assert_eq "$status" 0
	assert_eq "$stderr" ""
}

@test "FR28: a map or directory writable by group or others is unsafe" {
	local mode
	for mode in 620 602; do
		chmod "$mode" "$MAP"
		run_lendk run -- stub
		assert_eq "$stderr" "lendk: unsafe: $MAP is writable by others. Stop and ask the user."
		assert_class unsafe 125
	done
	chmod 600 "$MAP"
	for mode in 770 707 1777; do
		chmod "$mode" "$DIR"
		LENDK_PROMPT=allow run_lendk run -- stub
		assert_eq "$stderr" "lendk: unsafe: $DIR is writable by others. Fix it: chmod go-w $DIR, or recreate it as your own"
		assert_class unsafe 125
	done
	refute_target
}

@test "FR28: a symlinked map is judged by its target and the target's directory" {
	mkdir -m 700 "$SB/real"
	mv "$MAP" "$SB/real/map"
	ln -s ../../../real/map "$MAP"
	run_lendk run -- stub
	assert_eq "$status" 0
	chmod 770 "$SB/real"
	run_lendk run -- stub
	assert_eq "$stderr" "lendk: unsafe: $DIR/../../../real is writable by others. Stop and ask the user."
	assert_class unsafe 125
}

@test "FR28: a map owned by another user is unsafe" {
	[[ $(id -u) != 0 ]] || skip "root owns every path"
	LENDK_MAP=/etc/passwd run_lendk run -- stub
	assert_eq "$stderr" "lendk: unsafe: /etc is owned by another user. Stop and ask the user."
	assert_class unsafe 125
	refute_target
}
