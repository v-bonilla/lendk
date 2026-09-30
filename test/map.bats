#!/usr/bin/env bats
# The per-command map reader behind run: grammar, lists, groups and the lines it reads.

setup() {
	load helpers/common
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	export LEND_SHIMS=$SB/shims K1=one K2=two
	MAP=$HOME/.config/lend/map
}

# map LINE...: write a private map at the default path.
map() {
	mkdir -p "$HOME/.config/lend" && chmod 700 "$HOME/.config/lend"
	printf '%s\n' "$@" >"$MAP"
	chmod 600 "$MAP"
}

# injected: the LEND_INJECTED the one stub-target call received.
injected() {
	local logs=("$SB"/log/target.*)
	tr '\0' '\n' <"${logs[0]}/env" | sed -n 's/^LEND_INJECTED=//p'
}

@test "FR23: run reads only its own line and groups; bad lines elsewhere leave it working" {
	map '<<<<<<< HEAD' 'other K1' 'other K2' 'bad PATH' '@x @y' '@x K1' '1bad K1' '  stub   K1 @g	# trailing' '@g K2' '>>>>>>> branch' 'lend K1'
	run_lend run -- stub
	assert_eq "$status" 0
	assert_eq "$stderr" ""
}

@test "FR23: a violation in run's own line or groups is map, with its line" {
	local case line text
	for case in \
		"stub PATH|1|key 'PATH' is denied" \
		"stub LC_ALL|1|key 'LC_ALL' is denied" \
		"stub 9K|1|'9K' is not a valid key name" \
		"stub @a.b|1|'@a.b' is not a valid group name" \
		"stub|1|stub maps no keys" \
		"stub @nope|1|group @nope is not defined" \
		"stub @g,@g @h,@h K1|2|group @g holds @h; groups hold keys only" \
		"stub @g,@g|2|group @g holds no keys" \
		"stub @g,@g K1,@g K2|3|group @g is defined twice" \
		"stub K1,x K2,stub K2|3|stub is mapped twice"; do
		IFS=, read -ra lines <<<"${case%%|*}"
		map "${lines[@]}"
		line=${case#*|}
		text=${line#*|}
		line=${line%%|*}
		run_lend run -- stub
		assert_eq "$stderr" "lend: map: $MAP:$line: $text. Stop and ask the user."
		assert_class map 125
	done
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
}

@test "FR23: lend's own runtime cannot be mapped" {
	map 'bash K1'
	LEND_PROMPT=allow run_lend run -- bash
	assert_eq "$stderr" "lend: map: $MAP:1: bash is lend's own runtime and cannot be mapped. Fix the line, then run: lend check"
	assert_class map 125
}

@test "FR23: a named group must be defined; named keys need no map" {
	map 'stub K1'
	run_lend run @nope -- stub
	assert_eq "$stderr" "lend: map: $MAP: group @nope is not defined. Stop and ask the user."
	assert_class map 125
	rm "$MAP"
	run_lend run K1 -- stub
	assert_eq "$status" 0
	assert_eq "$(injected)" ""
}

@test "4.2: groups expand in word order and duplicates drop, keeping the first" {
	map 'stub K2 @g K1 # @late' '@g K1 K2 K3'
	export K3=three
	run_lend run -- stub
	assert_eq "$status" 0
	# shellcheck disable=SC2016
	LEND=$SB/bin/lend-fn run_lend eval 'load_env; expand_keys stub; printf "%s\n" "${keys[*]}"; expand_keys x K3 @g K3; printf "%s\n" "${keys[*]}"'
	assert_eq "$output" "K2 K1 K3
K3 K1 K2"
}
