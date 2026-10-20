#!/usr/bin/env bats
# lendk run: injection, resolution, exec and LENDK_INJECTED.
# shellcheck disable=SC2016,SC2030,SC2031,SC2329

setup() {
	load helpers/common
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	export LENDK_SHIMS=$SB/shims
	mkdir -p "$LENDK_SHIMS" && chmod 700 "$LENDK_SHIMS"
}

# map LINE...: write a private map at the default path.
map() {
	mkdir -p "$HOME/.config/lendk" && chmod 700 "$HOME/.config/lendk"
	printf '%s\n' "$@" >"$HOME/.config/lendk/map"
	chmod 600 "$HOME/.config/lendk/map"
}

# run_fake ARG...: lendk run ARG... with an entry value-KEY in the store for each key the map or ARG names.
run_fake() {
	local k
	for k in $(sed 's/#.*//' "$HOME/.config/lendk/map") "$@"; do
		[[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] && store_entry "$k" "value-$k"
	done
	run_lendk run "$@"
}

# reads: the keys the backend read, sorted.
reads() {
	local d
	for d in "$SB"/log/pass.*; do [[ -e $d/argv ]] && tr '\0' '\n' <"$d/argv" | sed -n 's|^env/||p'; done | sort
}

# target_env: the environment file the one stub-target call logged.
target_env() {
	local logs=("$SB"/log/target.*)
	assert_eq "${#logs[@]}" 1
	printf '%s\n' "${logs[0]}/env"
}

# env_diff A B [NAME...]: names whose entries differ between two env -0 files, less _ and NAME..., sorted.
env_diff() {
	local -A a=() b=()
	local e n skip=" _ ${*:3} "
	while IFS= read -r -d '' e; do a[${e%%=*}]=${e#*=}; done <"$1"
	while IFS= read -r -d '' e; do b[${e%%=*}]=${e#*=}; done <"$2"
	for n in "${!a[@]}" "${!b[@]}"; do
		[[ $skip == *" $n "* ]] && continue
		[[ ${a[$n]+x} == "${b[$n]+x}" && ${a[$n]-} == "${b[$n]-}" ]] || printf '%s\n' "$n"
	done | sort -u | tr '\n' ' '
}

# direct_env: the environment file of a direct call of the stub target, which the caller's
# environment reaches as it reaches lendk's target.
direct_env() {
	"$SB/bin/stub" </dev/null
	local logs=("$SB"/log/target.*)
	mv "${logs[0]}/env" "$SB/caller"
	rm -r "${logs[0]}"
}

# bats test_tags=port:rework
@test "with every key preset, only LENDK_INJECTED is added; exported functions and variables named like lendk's own stay" {
	map 'stub K1 K2'
	export K1=one K2=two map=m verbs=v timeout=t keys=k target=x
	fail() { echo caller-fail; }
	export -f fail
	env -0 >"$SB/caller"
	run_lendk run -- stub
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	assert_eq "$(env_diff "$SB/caller" "$(target_env)" PWD SHLVL)" "LENDK_INJECTED "
}

@test "the target's environment is a direct call's plus the injected keys and LENDK_INJECTED, SHLVL and PWD included" {
	map 'stub K1 @g' '@g K2 K3'
	export K3=preset SHLVL=7
	direct_env
	run_fake -- stub
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	assert_eq "$(env_diff "$SB/caller" "$(target_env)")" "K1 K2 LENDK_INJECTED "
}

# bats test_tags=port:only
@test "with every key preset, the target's environment is a direct call's plus LENDK_INJECTED; SHELLOPTS, BASHOPTS and exported functions stay" {
	map 'stub K1 K2'
	export K1=one K2=two map=m verbs=v timeout=t keys=k target=x
	export SHELLOPTS BASHOPTS
	fail() { echo caller-fail; }
	export -f fail
	direct_env
	# Not through run_lendk: a command substitution changes the SHELLOPTS bash exports.
	"$LENDK" run -- stub </dev/null 2>"$SB/stderr"
	assert_eq "$(<"$SB/stderr")" ""
	assert_eq "$(env_diff "$SB/caller" "$(target_env)")" "LENDK_INJECTED "
}

# bats test_tags=port:only
@test "the target's environment is the caller's entries in order, less those named like an injected key, then the keys and LENDK_INJECTED" {
	map 'envtgt K1 @g' '@g K2 K3'
	ln -s "$(type -P env)" "$SB/bin/envtgt"
	store_entry K1 "$SENTINEL-1"
	store_entry K2 "$SENTINEL-2"
	export K3=preset K1='' LENDK_INJECTED='X K1'
	env -0 | tr '\0' '\n' | grep -v '^_=' >"$SB/caller"
	"$LENDK" run -- envtgt -0 </dev/null 2>"$SB/stderr" | tr '\0' '\n' | grep -v '^_=' >"$SB/target"
	assert_eq "$(<"$SB/stderr")" ""
	assert_eq "$(<"$SB/target")" "$(grep -v -e '^K1=' -e '^LENDK_INJECTED=' "$SB/caller")
K1=$SENTINEL-1
K2=$SENTINEL-2
LENDK_INJECTED=X K1 K2"
}

# bats test_tags=port:retire
@test "an exported SHELLOPTS reaches the target with the caller's options" {
	map 'stub K1'
	export K1=one
	run bash -c 'set -o noclobber; export SHELLOPTS; env -0 >"$1/caller"; exec "$2" run -- stub </dev/null' _ "$SB" "$LENDK"
	assert_eq "$status" 0
	assert_eq "$(env_diff "$SB/caller" "$(target_env)" PWD SHLVL)" "LENDK_INJECTED "
}

@test "a key set non-empty by the caller is not read and keeps its value; an empty one is read" {
	map 'stub K1 K2'
	K1=caller K2='' run_fake -- stub
	assert_eq "$status" 0
	assert_eq "$(reads)" K2
	tr '\0' '\n' <"$(target_env)" | grep -qx K1=caller
	tr '\0' '\n' <"$(target_env)" | grep -qx K2=value-K2
}

@test "the first executable regular file on PATH runs, skipping the shim directory however it is reached" {
	map 'stub K1'
	export K1=one
	mkdir -p "$SB/noexec" "$SB/isdir/stub" "$SB/other"
	printf '#!/bin/sh\nexit 99\n' >"$LENDK_SHIMS/stub"
	chmod 755 "$LENDK_SHIMS/stub"
	printf '#!/bin/sh\nexit 98\n' >"$SB/noexec/stub"
	ln -s "$LENDK_SHIMS" "$SB/shimlink"
	ln -s "$LENDK_SHIMS/stub" "$SB/other/stub"
	PATH=$LENDK_SHIMS:$SB/shimlink:$SB/other:$SB/noexec:$SB/isdir:$PATH run_lendk run -- stub
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	target_env >/dev/null
}

@test "a CMD holding / is used as given, and a CMD found nowhere else is not-found" {
	map 'stub K1' 'nothere K1'
	export K1=one
	printf '#!/bin/sh\nexit 99\n' >"$LENDK_SHIMS/stub"
	chmod 755 "$LENDK_SHIMS/stub"
	run_lendk run -- "$LENDK_SHIMS/stub"
	assert_eq "$status" 99
	PATH=$LENDK_SHIMS:$PATH run_lendk run -- nothere
	assert_eq "$stderr" "lendk: not-found: nothere is not on PATH outside $LENDK_SHIMS. Install nothere, or ask the user."
	assert_class not-found 127
}

@test "the target gets argv0 as given, its arguments unchanged, and its status passes through" {
	map 'stub K1' 'tgt K1'
	export K1=one
	ln -s "$BASH" "$SB/bin/tgt"
	run_lendk run -- tgt -c 'printf %s "$0"'
	assert_eq "$output" tgt
	STUB_EXIT=7 run_lendk run -- stub 'a b' '' '*' --
	assert_eq "$status" 7
	assert_eq "$stderr" ""
	local logs=("$SB"/log/target.*)
	assert_eq "$(tr '\0' '|' <"${logs[0]}/argv")" 'a b||*|--|'
}

@test "lendk becomes the target, so SIGTERM reaches it" {
	map 'tgt K1'
	export K1=one OUT=$SB/got
	ln -s "$BASH" "$SB/bin/tgt"
	"$LENDK" run -- tgt -c 'trap "echo term >\"\$OUT\"; exit 3" TERM; echo $$ >"$OUT.pid"; sleep 10 & wait' </dev/null 2>"$SB/stderr" &
	local pid=$! i status=0
	for ((i = 0; i < 50; i++)); do [[ -s $OUT.pid ]] && break; sleep 0.1; done
	assert_eq "$(<"$OUT.pid")" "$pid"
	kill -TERM "$pid"
	wait "$pid" || status=$?
	assert_eq "$status" 3
	assert_eq "$(<"$OUT")" term
	assert_eq "$(<"$SB/stderr")" ""
}

@test "a target exec cannot run gives exec, never bash's own message" {
	map 'noexec K1' 'badinterp K1'
	export K1=one
	printf '#!/bin/sh\n' >"$SB/noexec"
	chmod 644 "$SB/noexec"
	run_lendk run -- "$SB/noexec"
	assert_eq "$stderr" "lendk: exec: $SB/noexec is not executable. Stop and ask the user."
	assert_class exec 126
	printf '#!/nonexistent/sh\n' >"$SB/badinterp"
	chmod 755 "$SB/badinterp"
	LENDK_PROMPT=allow run_lendk run -- "$SB/badinterp"
	assert_eq "$stderr" "lendk: exec: /nonexistent/sh is not executable. Fix it, or unmap it: lendk rm badinterp"
	assert_class exec 126
}

@test "named keys replace the map entry, and without them the entry for CMD's basename applies" {
	map 'stub A'
	run_fake B -- stub
	assert_eq "$status" 0
	assert_eq "$(reads)" B
	refute_contains "$(tr '\0' '\n' <"$(target_env)")" A=
	rm -r "$SB/log"
	run_fake -- "$SB/bin/stub"
	assert_eq "$status" 0
	assert_eq "$(reads)" A
}

@test "a CMD without an entry and without named keys is unmapped" {
	map 'stub A'
	run_lendk run -- other
	assert_eq "$stderr" "lendk: unmapped: other is not mapped. Stop and ask the user."
	assert_class unmapped 125
	rm "$HOME/.config/lendk/map"
	LENDK_PROMPT=allow run_lendk run -- stub
	assert_eq "$stderr" "lendk: unmapped: stub is not mapped. Map it: lendk add stub KEY..., or name keys: lendk run KEY... -- stub"
	assert_class unmapped 125
}

@test "LENDK_INJECTED holds the caller's names, then the names this call exported, once each" {
	map 'stub A B C A'
	B=preset LENDK_INJECTED='X B X' run_fake -- stub
	assert_eq "$status" 0
	tr '\0' '\n' <"$(target_env)" | grep -qx 'LENDK_INJECTED=X B A C'
}

@test "run without -- is usage, naming a word that is a command" {
	run_lendk run K1 stub
	assert_eq "$stderr" "lendk: usage: 'stub' is a command; put -- before it. See: lendk --help"
	assert_class usage 2
	run_lendk run K1
	assert_eq "$stderr" "lendk: usage: run needs -- before the command. See: lendk --help"
	assert_class usage 2
	run_lendk run K1 --
	assert_eq "$stderr" "lendk: usage: run needs a command after --. See: lendk --help"
	assert_class usage 2
}

@test "named words must be valid, allowed keys or groups" {
	local word
	for word in 1BAD PATH LENDK_X BASH_ENV @ '@a.b' --force; do
		run_lendk run "$word" -- stub
		assert_class usage 2
	done
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
}

# bats test_tags=port:retire
@test "the preset path forks as often for a 50-line map and a long PATH as for one line and a short PATH" {
	require strace
	local i lines=() long=$PATH count1 count2
	export K1=one
	map 'stub K1'
	strace -f -qq -e trace=fork,vfork,clone,clone3 -o "$SB/short" "$LENDK" run -- stub </dev/null
	for ((i = 0; i < 49; i++)); do lines+=("cmd$i K1 K2"); done
	map "${lines[@]}" 'stub K1'
	for ((i = 0; i < 30; i++)); do long=$SB/none$i:$long; done
	PATH=$long strace -f -qq -e trace=fork,vfork,clone,clone3 -o "$SB/long" "$LENDK" run -- stub </dev/null
	count1=$(grep -cE '^[0-9]+ +(fork|vfork|clone|clone3)\(' "$SB/short")
	count2=$(grep -cE '^[0-9]+ +(fork|vfork|clone|clone3)\(' "$SB/long")
	((count1 > 0))
	assert_eq "$count2" "$count1"
}

# run_raw ARG...: lendk ARG... without run_lendk's contract check; sets status and stderr.
run_raw() {
	status=0
	"$LENDK" "$@" </dev/null 2>"$SB/stderr" || status=$?
	stderr=$(<"$SB/stderr")
}

# junk: an executable file the kernel refuses to run.
junk() {
	printf 'junk\0\1binary' >"$SB/junk"
	chmod 755 "$SB/junk"
}

@test "when the kernel refuses the file, lendk's exec line ends stderr, also under a caller BASHOPTS without execfail" {
	map 'junk K1' 'busy K1'
	export K1=one
	junk
	run_raw run -- "$SB/junk"
	assert_eq "${stderr##*$'\n'}" "lendk: exec: $SB/junk is not executable. Stop and ask the user."
	assert_eq "$status" 126
	status=0
	env BASHOPTS=cmdhist "$LENDK" run -- "$SB/junk" </dev/null 2>"$SB/stderr" || status=$?
	stderr=$(<"$SB/stderr")
	assert_eq "${stderr##*$'\n'}" "lendk: exec: $SB/junk is not executable. Stop and ask the user."
	assert_eq "$status" 126
	# Only Linux refuses to run a file open for writing (ETXTBSY).
	[[ $(uname -s) == Linux ]] || return 0
	cp -L "$(type -P env)" "$SB/busy"
	exec 7>>"$SB/busy"
	run_raw run -- "$SB/busy"
	exec 7>&-
	assert_eq "${stderr##*$'\n'}" "lendk: exec: $SB/busy is not executable. Stop and ask the user."
	assert_eq "$status" 126
}

# bats test_tags=port:retire
@test "caller functions named like lendk's own leave the exec error path intact" {
	map 'junk K1'
	export K1=one
	junk
	fail() { echo caller-fail; }
	set_paths() { echo caller-set_paths; }
	class_line() { echo caller-class_line; }
	export -f fail set_paths class_line
	run_raw run -- "$SB/junk"
	assert_eq "${stderr##*$'\n'}" "lendk: exec: $SB/junk is not executable. Stop and ask the user."
	assert_eq "$status" 126
}

# bats test_tags=port:retire
@test "an exported POSIXLY_CORRECT reaches the target unchanged, and lendk runs" {
	map 'stub K1'
	export K1=one
	env POSIXLY_CORRECT=1 env -0 >"$SB/caller"
	env POSIXLY_CORRECT=1 "$LENDK" run -- stub </dev/null 2>"$SB/stderr"
	assert_eq "$(<"$SB/stderr")" ""
	assert_eq "$(env_diff "$SB/caller" "$(target_env)" PWD SHLVL)" "LENDK_INJECTED "
}

# bats test_tags=port:retire
@test "caller variables named like lendk's internals change nothing" {
	map 'stub K1'
	export K1=one lendk_target=/bin/false lendk_env=x lendk_k=y lendk_late=z lendk_listing=w
	env -0 >"$SB/caller"
	run_lendk run -- stub
	assert_eq "$status" 0
	assert_eq "$(env_diff "$SB/caller" "$(target_env)" PWD SHLVL)" "LENDK_INJECTED "
}

@test "keys named lendk_ in any case are denied" {
	local word
	for word in lendk_target Lendk_x lendk_k; do
		run_lendk run "$word" -- stub
		assert_eq "$stderr" "lendk: usage: key '$word' is denied. See: lendk --help"
		assert_class usage 2
	done
}

@test "a CMD whose basename breaks the CMD grammar is usage" {
	local cmd
	map 'stub K1' '@g K1'
	for cmd in /tmp/ 'a b' @g; do
		run_lendk run -- "$cmd"
		assert_eq "$stderr" "lendk: usage: '$cmd' names no valid command. See: lendk --help"
		assert_class usage 2
	done
}

# bats test_tags=port:retire
@test "a caller BASHOPTS with nocasematch does not make STUB match stub" {
	map 'stub K1'
	export K1=one
	env BASHOPTS=nocasematch "$LENDK" run -- STUB </dev/null 2>"$SB/stderr" || true
	assert_eq "$(<"$SB/stderr")" "lendk: unmapped: STUB is not mapped. Stop and ask the user."
}

# bats test_tags=port:retire
@test "lendk's own helpers come from the system path, never from PATH or the shims" {
	map 'ls K1'
	export K1=one
	printf '#!/bin/sh\necho fake >&2\nexit 1\n' >"$SB/bin/readlink"
	chmod 755 "$SB/bin/readlink"
	printf '#!/bin/sh\nexec %q run -- ls "$@"\n' "$LENDK" >"$LENDK_SHIMS/ls"
	chmod 755 "$LENDK_SHIMS/ls"
	mkdir "$SB/real" && chmod 700 "$SB/real"
	mv "$HOME/.config/lendk/map" "$SB/real/map"
	ln -s "$SB/real/map" "$HOME/.config/lendk/map"
	PATH=$LENDK_SHIMS:$PATH run timeout 10 "$LENDK" run -- ls -d / </dev/null
	assert_eq "$status" 0
	assert_eq "$output" /
	rm "$HOME/.config/lendk/map"
	mv "$SB/real/map" "$HOME/.config/lendk/map"
	PATH=$LENDK_SHIMS:$PATH run timeout 10 "$LENDK" run -- ls -d / </dev/null
	assert_eq "$status" 0
	assert_eq "$output" /
}

@test "the target inherits the caller's limits, ignored and blocked signals, descriptors and closed stdio" {
	[[ -d /proc/self ]] || skip "no /proc"
	require perl
	local f
	map 'probe K1'
	store_entry K1 "$SENTINEL"
	printf '#!%s\ngrep -E "^Sig(Ign|Blk):" /proc/$$/status >"$STUB_LOG/$1.sig"\nulimit -a >"$STUB_LOG/$1.lim"\ncd /proc/$$/fd && echo * >"$STUB_LOG/$1.fds"\n' "$BASH" >"$SB/bin/probe"
	chmod 755 "$SB/bin/probe"
	# call CMD...: CMD with SIGPIPE and SIGUSR2 ignored, SIGUSR1 blocked, fewer open files, fd 7
	# open, and stdin and stdout closed.
	call() {
		(
			ulimit -n 200
			trap '' PIPE USR2
			exec 7>"$SB/fd7" <&- >&-
			# perl puts /dev/null on closed stdio, so it closes them again before exec.
			perl -MPOSIX -e 'sigprocmask(SIG_BLOCK, POSIX::SigSet->new(SIGUSR1)); POSIX::close(0); POSIX::close(1); exec @ARGV or exit 127' "$@"
		) 2>"$SB/stderr"
	}
	call probe direct
	call "$LENDK" run -- probe lendk
	assert_eq "$(<"$SB/stderr")" ""
	for f in sig lim fds; do
		assert_eq "$(<"$SB/log/lendk.$f")" "$(<"$SB/log/direct.$f")"
	done
	grep -q '^SigIgn:.*[1-9a-f]' "$SB/log/direct.sig"
	grep -q '^SigBlk:.*[1-9a-f]' "$SB/log/direct.sig"
	refute_contains " $(<"$SB/log/direct.fds") " " 1 "
}
