#!/usr/bin/env bats
# lend add and rm: map edits (FR24, FR25, FR27) under the lock (FR26), with the map rules (FR23, FR28).
# shellcheck disable=SC2030,SC2031

setup() {
	load helpers/common
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	ln -s "$FIXTURES/stub-target" "$SB/bin/other"
	export LEND_SHIMS=$SB/shims
	SHIMS=$LEND_SHIMS
	MAP=$HOME/.config/lend/map
	stub_gpg 2.4.4
	keys K1 K2 K3
}

# map LINE...: write a private map at the default path.
map() {
	mkdir -p "$HOME/.config/lend" && chmod 700 "$HOME/.config/lend"
	printf '%s\n' "$@" >"$MAP"
	chmod 600 "$MAP"
}

# keys KEY...: store entries for KEY....
keys() {
	local k
	for k; do printf 'value\n' >"$SB/store/env/$k.gpg"; done
}

# stub_gpg VERSION: gpg and gpg2 on PATH reporting VERSION.
stub_gpg() {
	local g
	for g in gpg gpg2; do
		printf '#!/bin/sh\necho "gpg (GnuPG) %s"\n' "$1" >"$SB/bin/$g"
		chmod +x "$SB/bin/$g"
	done
}
# state: the map and every shim, byte for byte, and which shims are executable.
# state: the map and every shim, byte for byte, with modes.
state() {
	cat "$MAP" 2>/dev/null
	local f
	for f in "$SHIMS"/*; do [[ ! -x $f ]] || printf 'x %s\n' "${f##*/}"; done
	(cd "$SHIMS" 2>/dev/null && cksum -- *) || true
}

@test "FR24: add creates an entry, syncs and prints its row in check format" {
	run_lend add stub K1 K2
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	assert_eq "$output" $'stub\tK1 K2\tok'
	assert_eq "$(cat "$MAP")" 'stub K1 K2'
	[[ -x $SHIMS/stub ]]
	PATH=$SHIMS:$PATH stub
	local logs=("$SB"/log/target.*)
	tr '\0' '\n' <"${logs[0]}/env" | grep -qx 'K1=value'
	assert_eq "$(compgen -G "$SB/log/pass.*" | wc -l)" 2
}

@test "FR24: add appends only absent words, in order, before a trailing comment" {
	map '# keys' 'stub   K1    # the stub' '@g K3' 'other K1'
	run_lend add stub K2 K1 @g K2
	assert_eq "$status" 0
	assert_eq "$(cat "$MAP")" $'# keys\nstub   K1 K2 @g    # the stub\n@g K3\nother K1'
	assert_eq "$output" $'stub\tK1 K2 @g\tok'
	run_lend add @g K1
	assert_eq "$status" 0
	assert_eq "$(sed -n 3p "$MAP")" '@g K3 K1'
	assert_eq "$output" $'@g\tK3 K1\tok\nstub\tK1 K2 @g\tok'
	local before
	before=$(state)
	run_lend add stub K1
	assert_eq "$status" 0
	assert_eq "$(state)" "$before"
}

@test "FR24: rm removes words, the entry when none remain, and the shim with it" {
	map 'stub K1 K2 # note' 'other K1'
	run_lend sync
	run_lend rm stub K1
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	assert_eq "$(cat "$MAP")" $'stub K2 # note\nother K1'
	assert_eq "$output" $'stub\tK2\tok'
	run_lend rm stub K2
	assert_eq "$status" 0
	assert_eq "$output" ""
	assert_eq "$(cat "$MAP")" 'other K1'
	[[ ! -e $SHIMS/stub && -e $SHIMS/other ]]
	run_lend rm other
	assert_eq "$status" 0
	assert_eq "$(cat "$MAP")" ''
	assert_eq "$(ls "$SHIMS")" ''
}

@test "FR24: a guarded command needs --force, and --force gives a notice naming the risk" {
	ln -s "$FIXTURES/stub-target" "$SB/bin/python3"
	map 'stub K1'
	local before cmd
	before=$(state)
	for cmd in sh python3 env npx claude; do
		run_lend add "$cmd" K1
		assert_eq "$stderr" "lend: guarded: $cmd runs other programs, so its keys reach all of them. Stop and ask the user."
		assert_class guarded 2
	done
	LEND_PROMPT=allow run_lend add python3 K1
	assert_eq "$stderr" "lend: guarded: python3 runs other programs, so its keys reach all of them. To map it anyway: lend add --force python3 WORD..."
	assert_eq "$(state)" "$before"
	run_lend add --force python3 K1
	assert_eq "$status" 0
	assert_eq "$stderr" "lend: notice: python3 runs other programs, so its keys reach all of them."
	assert_eq "$output" $'python3\tK1\tok'
	[[ -x $SHIMS/python3 ]]
}

@test "FR25: every add and rm error leaves the map and shims byte-identical" {
	map 'stub K1 @g' '@g K2' 'other K1'
	run_lend sync
	local before args
	before=$(state)
	while IFS='|' read -r class args; do
		# shellcheck disable=SC2086
		run_lend $args
		assert_class "$class" "$([[ $class == usage ]] && echo 2 || echo 125)"
		assert_eq "$(state)" "$before"
	done <<-'EOF'
		usage|add stub
		usage|add
		usage|rm
		usage|add -x K1
		usage|add lend K1
		usage|add gpg-agent K1
		usage|add stub 1K
		usage|add stub PATH
		usage|add stub LD_PRELOAD
		usage|add stub lend_x
		usage|add @g @h
		usage|add @bad! K1
		usage|rm stub PATH
		usage|rm @g @h
		usage|add stub --force
		map|add stub @nope
		map|rm @g
		map|rm @g K2
	EOF
}

@test "FR25: removing an absent name or word exits 0 with a notice" {
	map 'stub K1'
	run_lend sync
	local before
	before=$(state)
	run_lend rm other
	assert_eq "$status" 0
	assert_eq "$stderr" "lend: notice: other is not in $MAP, so nothing changed."
	run_lend rm stub K9
	assert_eq "$status" 0
	assert_eq "$stderr" "lend: notice: stub does not hold K9, so nothing changed for it."
	assert_eq "$output" $'stub\tK1\tok'
	assert_eq "$(state)" "$before"
}

@test "FR23: add and rm need the whole map valid" {
	map 'stub K1' 'bad!name K1' 'other K1' 'other K2'
	local before
	before=$(state)
	run_lend add stub K2
	assert_eq "$stderr" "lend: map: $MAP:2: 'bad!name' is not a valid command name. Stop and ask the user."$'\n'"lend: map: $MAP:4: other is mapped twice. Stop and ask the user."
	assert_class map 125
	run_lend rm stub
	assert_class map 125
	assert_eq "$(state)" "$before"
}

@test "FR26: twenty concurrent adds started with a dead owner's lock leave twenty entries" {
	local i p st=0
	mkdir -m 700 "$SHIMS" "$SHIMS.lock"
	sh -c 'exit 0' &
	p=$!
	wait "$p"
	printf '%s\n' "$p" >"$SHIMS.lock/pid"
	for ((i = 1; i <= 20; i++)); do
		ln -s "$FIXTURES/stub-target" "$SB/bin/c$i"
		"$LEND" add "c$i" K1 </dev/null >/dev/null 2>"$SB/err.$i" &
	done
	for ((i = 1; i <= 20; i++)); do wait -n || st=$?; done
	assert_eq "$(cat "$SB"/err.*)" ""
	assert_eq "$st" 0
	assert_eq "$(sort "$MAP")" "$(for ((i = 1; i <= 20; i++)); do echo "c$i K1"; done | sort)"
	assert_eq "$(find "$SHIMS" -type f | wc -l)" 20
	assert_eq "$(compgen -G "$SHIMS.lock*")" ""
	assert_eq "$(ls -A "$HOME/.config/lend")" map
}

@test "FR27: the map is 0600 in a 0700 directory under umask 000, and only the edited line changes" {
	umask 000
	run_lend add stub K1
	assert_eq "$status" 0
	[[ $(ls -ln "$MAP") == -rw-------* ]]
	[[ $(ls -lnd "$HOME/.config/lend") == drwx------* ]]
	printf '# top\r\n\n@g K2   # keep  this\n' >>"$MAP"
	chmod 644 "$MAP"
	run_lend add other K1
	assert_eq "$status" 0
	[[ $(ls -ln "$MAP") == -rw-------* ]]
	assert_eq "$(cat "$MAP")" $'stub K1\n# top\r\n\n@g K2   # keep  this\nother K1'
	assert_eq "$(ls -A "$HOME/.config/lend")" map
}

@test "FR27: a symlinked map is followed, and the link stays" {
	mkdir -m 700 "$SB/dots" "$HOME/.config" "$HOME/.config/lend"
	printf 'stub K1\n' >"$SB/dots/map"
	chmod 600 "$SB/dots/map"
	ln -s "$SB/dots/map" "$MAP"
	run_lend add other K2
	assert_eq "$status" 0
	[[ -L $MAP ]]
	assert_eq "$(cat "$SB/dots/map")" $'stub K1\nother K2'
	[[ $(ls -ln "$SB/dots/map") == -rw-------* ]]
	run_lend rm stub
	assert_eq "$status" 0
	[[ -L $MAP ]]
	assert_eq "$(cat "$SB/dots/map")" 'other K2'
}

@test "FR28: add and rm give unsafe for an open map, map directory or shim directory" {
	map 'stub K1'
	run_lend sync
	local before
	chmod 620 "$MAP"
	before=$(state)
	run_lend add other K1
	assert_eq "$stderr" "lend: unsafe: $MAP is writable by others. Stop and ask the user."
	assert_class unsafe 125
	assert_eq "$(state)" "$before"
	chmod 600 "$MAP"
	chmod 770 "$SHIMS"
	run_lend rm stub
	assert_eq "$stderr" "lend: unsafe: $SHIMS is writable by others. Stop and ask the user."
	chmod 700 "$SHIMS"
	rm "$MAP"
	chmod 770 "$HOME/.config/lend"
	run_lend add stub K1
	assert_eq "$stderr" "lend: unsafe: $HOME/.config/lend is writable by others. Stop and ask the user."
	[[ ! -e $MAP ]]
}

@test "FR24: rows for non-interactive callers say ask the user, never add or rm" {
	run_lend add stub K1 K9
	assert_eq "$status" 0
	assert_eq "$output" $'stub\tK1 K9\tenv/K9 is not in the store (ask the user)'
	refute_contains "$output" 'lend add'
	LEND_PROMPT=allow run_lend add stub K9
	assert_eq "$output" $'stub\tK1 K9\tenv/K9 is not in the store (pass insert env/K9)'
}

@test "FR25: an unknown group creates nothing, and its FIX says to define the group" {
	run_lend add stub @nope
	assert_eq "$stderr" "lend: map: $MAP: group @nope is not defined. Stop and ask the user."
	assert_class map 125
	[[ ! -e $SHIMS && ! -e $SHIMS.lock && ! -e $HOME/.config ]]
	LEND_PROMPT=allow run_lend add stub @nope
	assert_eq "$stderr" "lend: map: $MAP: group @nope is not defined. Define it first: lend add @nope KEY..."
	[[ ! -e $SHIMS ]]
}
