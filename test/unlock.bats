#!/usr/bin/env bats
# FR34, and FR23 and FR28 for unlock, with the call-logging fake pass.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034

setup() {
	load helpers/common
	sandbox
	MAP=$HOME/.config/lendk/map
	mkdir -p "$HOME/.config/lendk" && chmod 700 "$HOME/.config/lendk"
	printf '@pair K1 K2\nstub K3 @pair\n' >"$MAP"
	chmod 600 "$MAP"
	for k in K1 K2 K3; do printf '%s-%s\n' "$SENTINEL" "$k" >"$SB/store/env/$k.gpg"; done
}

# read_calls: the entries the fake pass was asked for, in order.
read_calls() {
	local p
	[[ -f $SB/log/pids ]] || return 0
	while read -r p; do
		[[ ! -f $SB/log/pass.$p/argv ]] || { tr '\0' ' ' <"$SB/log/pass.$p/argv" && echo; }
	done <"$SB/log/pids"
}

@test "FR34: unlock decrypts each named key, groups inlined, prints unlocked and no value" {
	run_lendk unlock K3 @pair
	assert_eq "$stderr" ""
	assert_eq "$output" unlocked
	assert_eq "$status" 0
	assert_eq "$(read_calls)" $'show env/K3 \nshow env/K1 \nshow env/K2 '
}

@test "FR34: without names, unlock decrypts the first mapped key present in the store" {
	rm "$SB/store/env/K1.gpg"
	run_lendk unlock
	assert_eq "$output" unlocked
	assert_eq "$status" 0
	assert_eq "$(read_calls)" 'show env/K2 '
}

@test "FR34: no mapped key present gives missing-key, and a missing named key too" {
	rm "$SB/store/env/"K?.gpg
	run_lendk unlock
	assert_class missing-key 125
	assert_eq "$stderr" "lendk: missing-key: no key mapped in $MAP is in the store. Stop and ask the user."
	LENDK_PROMPT=allow run_lendk unlock
	assert_eq "$stderr" "lendk: missing-key: no key mapped in $MAP is in the store. Add a mapped key with pass insert, then retry."
	rm "$MAP"
	LENDK_PROMPT=allow run_lendk unlock
	assert_class missing-key 125
	assert_eq "$stderr" "lendk: missing-key: $MAP does not exist. Create it with lendk add, or name the keys to unlock."
	run_lendk unlock K9
	assert_eq "$stderr" "lendk: missing-key: env/K9 is not in the store. Stop and ask the user."
	assert_eq "$(compgen -G "$SB/log/pass.*")" ""
}

@test "FR34: unlock follows run's classes: locked, canceled, timeout, usage" {
	echo locked >"$SB/store/env/K1.mode"
	run_lendk unlock K1
	assert_eq "$stderr" "lendk: locked: env/K1 needs the gpg passphrase and this call cannot prompt. Ask the user to run 'lendk unlock K1' in a terminal, then retry."
	assert_eq "$output" ""
	echo cancel >"$SB/store/env/K1.mode"
	LENDK_PROMPT=allow run_lendk unlock K1
	assert_class canceled 120
	echo hang >"$SB/store/env/K1.mode"
	LENDK_TIMEOUT=1 run_lendk unlock K1
	assert_class timeout 120
	assert_eq "$(ls -A "$TMPDIR")" ""
	run_lendk unlock 'bad-name'
	assert_class usage 2
	LENDK_PROMPT=maybe run_lendk unlock K1
	assert_class usage 2
}

@test "FR23: unlock reads only the lines its groups need" {
	printf '<<<<<<< HEAD\nstub K1\nstub K2\n@pair K1 K2\n@bad LENDK_X\n' >"$MAP"
	run_lendk unlock @pair K3
	assert_eq "$output" unlocked
	assert_eq "$status" 0
	run_lendk unlock @bad
	assert_class map 125
	assert_eq "$stderr" "lendk: map: $MAP:5: key 'LENDK_X' is denied. Stop and ask the user."
	run_lendk unlock @none
	assert_class map 125
}

@test "FR28: unlock gives unsafe for a group-writable map or map directory" {
	chmod 620 "$MAP"
	run_lendk unlock K1
	assert_class unsafe 125
	assert_eq "$stderr" "lendk: unsafe: $MAP is writable by others. Stop and ask the user."
	chmod 600 "$MAP"
	chmod 770 "${MAP%/*}"
	run_lendk unlock K1
	assert_class unsafe 125
	assert_eq "$(compgen -G "$SB/log/pass.*")" ""
}
