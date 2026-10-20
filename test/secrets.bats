#!/usr/bin/env bats
# The decrypt path: order, values, export timing, the caller's umask and descriptors, and where values go.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
	load helpers/common
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	export LENDK_SHIMS=$SB/shims
	mkdir -p "$LENDK_SHIMS" && chmod 700 "$LENDK_SHIMS"
}

map() {
	mkdir -p "$HOME/.config/lendk" && chmod 700 "$HOME/.config/lendk"
	printf '%s\n' "$@" >"$HOME/.config/lendk/map"
	chmod 600 "$HOME/.config/lendk/map"
}

# entry KEY VALUE: store VALUE, a newline and a second line as KEY's entry.
entry() { store_entry "$1" "$2" 'second line'; }

# target_var NAME: NAME's value in the one stub-target call's environment.
target_var() {
	local logs=("$SB"/log/target.*) e
	assert_eq "${#logs[@]}" 1
	while IFS= read -r -d '' e; do [[ ${e%%=*} == "$1" ]] && printf '%s' "${e#*=}"; done <"${logs[0]}/env"
}

# pass_logs: the fake pass call directories.
pass_logs() { compgen -G "$SB/log/pass.*"; }

# no_sentinel: the sentinel is in no file under HOME, TMPDIR or the store's siblings but the target's log.
no_sentinel() {
	local hits
	hits=$(grep -rlF -- "$SENTINEL" "$HOME" "$TMPDIR" "$SB"/log/pass.* 2>/dev/null) || true
	assert_eq "$hits" "" || { grep -rF -- "$SENTINEL" "$HOME" "$TMPDIR" "$SB"/log/pass.* >&2; return 1; }
}

@test "every missing key is listed before any decrypt, and the command does not run" {
	map 'stub K1 K2 K3'
	entry K2 "$SENTINEL"
	run_lendk run -- stub
	assert_eq "$stderr" "lendk: missing-key: env/K1 is not in the store. Stop and ask the user.
lendk: missing-key: env/K3 is not in the store. Stop and ask the user."
	assert_class missing-key 125
	assert_eq "$(pass_logs)" ""
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
}

@test "the command resolves before anything is decrypted" {
	map 'nothere K1'
	entry K1 "$SENTINEL"
	run_lendk run -- nothere
	assert_class not-found 127
	assert_eq "$(pass_logs)" ""
}

@test "a failed decrypt stops the call with gpg's last line, and the command does not run" {
	map 'stub K1 K2'
	entry K1 one
	entry K2 two
	printf '#!/bin/sh\necho "gpg: first" >&2\necho "gpg: decryption failed: No secret key" >&2\nexit 2\n' >"$SB/bin/failpass"
	chmod 755 "$SB/bin/failpass"
	rm "$SB/bin/pass"
	ln -s "$SB/bin/failpass" "$SB/bin/pass"
	run_lendk run -- stub
	assert_eq "$stderr" "lendk: decrypt: env/K1: gpg says: decryption failed: No secret key. Ask the user to run 'lendk unlock K1' in a terminal, then retry."
	assert_class decrypt 125
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
	assert_eq "$(ls -A "$TMPDIR")" ""
}

@test "a later backend call sees no key read earlier; all keys reach the target" {
	map 'stub K1 K2'
	entry K1 "$SENTINEL-1"
	entry K2 "$SENTINEL-2"
	run_lendk run -- stub
	assert_eq "$status" 0
	local logs log
	mapfile -t logs < <(pass_logs)
	assert_eq "${#logs[@]}" 2
	for log in "${logs[@]}"; do
		refute_contains $'\n'"$(tr '\0' '\n' <"$log/env")" $'\nK1='
		refute_contains $'\n'"$(tr '\0' '\n' <"$log/env")" $'\nK2='
		refute_contains "$(tr '\0' '\n' <"$log/env")" "$SENTINEL"
	done
	assert_eq "$(target_var K1)" "$SENTINEL-1"
	assert_eq "$(target_var K2)" "$SENTINEL-2"
}

# A lendk that is not dumpable keeps its own memory, and so the target's environment at execve,
# and its helpers' until they exec, from a tracer of the same user; the calls of the helpers'
# own children, which carry the helper environment, stay readable.
@test "under strace the sentinel appears in no execve but lendk's own start, and the target receives it" {
	require strace
	map 'tgt K1 K2'
	entry K1 "$SENTINEL-1"
	entry K2 "$SENTINEL-2"
	printf '#!/bin/sh\n[ "$K1" = "$E1" ] && [ "$K2" = "$E2" ]\n' >"$SB/bin/tgt"
	chmod 755 "$SB/bin/tgt"
	local status=0 hits
	E1=$SENTINEL-1 E2=$SENTINEL-2 strace -f --seccomp-bpf -v -s 4096 -e trace=execve -o "$SB/trace" "$LENDK" run -- tgt </dev/null 2>"$SB/stderr" || status=$?
	assert_eq "$(<"$SB/stderr")" ""
	assert_eq "$status" 0
	hits=$(grep -F -- "$SENTINEL" "$SB/trace")
	assert_eq "$(grep -c . <<<"$hits")" 1
	[[ $hits == *"execve(\"$LENDK\", [\"$LENDK\", \"run\", \"--\", \"tgt\"], ["* ]]
	grep -qF '"PASSWORD_STORE_GPG_OPTS=--status-fd 9 --pinentry-mode error"' "$SB/trace"
}

@test "the target gets the caller's umask and descriptors, and lendk's files are private, under umask 000 and 022" {
	map 'tgt K1'
	entry K1 "$SENTINEL"
	printf '#!/bin/sh\numask >"$STUB_LOG/umask"\n{ echo open >&7; } 2>/dev/null\n' >"$SB/bin/tgt"
	chmod 755 "$SB/bin/tgt"
	local mask modes
	for mask in 000 022; do
		rm -rf "$SB/log" && mkdir "$SB/log"
		(umask "$mask" && exec 7>"$SB/fd7" && "$LENDK" run -- tgt </dev/null 2>"$SB/stderr")
		assert_eq "$(<"$SB/stderr")" ""
		assert_eq "$(<"$SB/log/umask")" "0$mask"
		assert_eq "$(<"$SB/fd7")" open
		modes=$(cut -c1-10 "$(pass_logs)/stderr-modes")
		assert_eq "$modes" $'drwx------\n-rw-------'
	done
}

@test "the target's open descriptors are exactly those of a direct call" {
	map 'stub K1'
	entry K1 "$SENTINEL"
	local logs
	(exec 7>"$SB/fd7" && "$SB/bin/stub" </dev/null 2>"$SB/stderr")
	logs=("$SB"/log/target.*)
	mv "${logs[0]}/fds" "$SB/direct"
	rm -rf "$SB/log" && mkdir "$SB/log"
	(exec 7>"$SB/fd7" && "$LENDK" run -- stub </dev/null 2>"$SB/stderr")
	logs=("$SB"/log/target.*)
	assert_eq "$(<"${logs[0]}/fds")" "$(<"$SB/direct")"
}

@test "the value is the first line without its newline, spaces and glob characters kept" {
	map 'stub K1'
	store_entry K1 '  a * b\n  ' second
	run_lendk run -- stub
	assert_eq "$status" 0
	assert_eq "$(target_var K1)" '  a * b\n  '
}

@test "an empty first line or an empty entry is missing-key" {
	map 'stub K1'
	store_entry K1 '' second
	run_lendk run -- stub
	assert_eq "$stderr" "lendk: missing-key: env/K1 has an empty first line. Stop and ask the user."
	assert_class missing-key 125
	store_entry K1
	LENDK_PROMPT=allow run_lendk run -- stub
	assert_eq "$stderr" "lendk: missing-key: env/K1 has an empty first line. Set it: pass edit env/K1"
	assert_class missing-key 125
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
	assert_eq "$(ls -A "$TMPDIR")" ""
}

@test "the sentinel reaches no output, file or helper, also through a nested call" {
	map 'stub K1' 'nest K2'
	entry K1 "$SENTINEL"
	entry K2 "$SENTINEL-2"
	run_lendk run -- stub
	assert_eq "$status" 0
	refute_contains "$output$stderr" "$SENTINEL"
	no_sentinel
	rm -rf "$SB/log" && mkdir "$SB/log"
	# A nested call: the outer target's key is preset for the inner lendk.
	printf '#!/bin/sh\nexec %q run -- stub\n' "$LENDK" >"$SB/bin/nest"
	chmod 755 "$SB/bin/nest"
	run_lendk run K2 -- nest
	assert_eq "$status" 0
	refute_contains "$output$stderr" "$SENTINEL"
	no_sentinel
	assert_eq "$(target_var K2)" "$SENTINEL-2"
}

@test "lendk leaves stdin to the target, and the backend's stdin is /dev/null" {
	map 'tgt K1'
	entry K1 "$SENTINEL"
	printf '#!/bin/sh\ncat >"$STUB_LOG/stdin"\n' >"$SB/bin/tgt"
	chmod 755 "$SB/bin/tgt"
	printf 'line one\nline two\n' | "$LENDK" run -- tgt 2>"$SB/stderr"
	assert_eq "$(<"$SB/stderr")" ""
	assert_eq "$(<"$SB/log/stdin")" $'line one\nline two'
	assert_eq "$(<"$(pass_logs)/stdin")" /dev/null
}

@test "LENDK_TEST_PAUSE never changes a decrypt's output or class, and no value reaches stderr" {
	local p
	map 'stub K1 K2'
	entry K1 "12$SENTINEL"
	entry K2 "7 $SENTINEL"
	for p in 1 x 10 -1 ''; do
		rm -rf "$SB/log" && mkdir "$SB/log"
		LENDK_TEST_PAUSE=$p run_lendk run -- stub
		assert_eq "$stderr" ""
		assert_eq "$status" 0
		assert_eq "$(target_var K1)" "12$SENTINEL"
		assert_eq "$(target_var K2)" "7 $SENTINEL"
	done
}

@test "at LENDK_TEST_PAUSE, lendk's environment is not its user's to read and its locked memory covers the values" {
	[[ -d /proc/self ]] || skip "no /proc"
	map 'stub K1'
	entry K1 "$SENTINEL"
	LENDK_TEST_PAUSE=3 "$LENDK" run -- stub </dev/null 2>"$SB/stderr" &
	local pid=$! i log='' lck owner
	for ((i = 0; i < 50; i++)); do
		log=$(compgen -G "$SB/log/pass.*") && [[ -s $log/pid ]] && gone "$(<"$log/pid")" && break
		sleep 0.1
	done
	[[ -n $log ]]
	[[ -e /proc/$pid/environ ]]
	owner=mine
	[[ -O /proc/$pid/environ ]] || owner=other
	assert_line "$(family)" "$pid"
	lck=$(sed -n 's/^VmLck:[[:space:]]*\([0-9]*\) kB$/\1/p' "/proc/$pid/status")
	wait "$pid"
	assert_eq "$owner" other
	((lck * 1024 >= ${#SENTINEL} + 3)) || { echo "VmLck: $lck kB" >&2; return 1; }
	assert_eq "$(<"$SB/stderr")" ""
	assert_eq "$(target_var K1)" "$SENTINEL"
}

@test "under a 64 KiB memlock limit, a call with four keys of ordinary length locks the memory that holds the values" {
	[[ -d /proc/self ]] || skip "no /proc"
	map 'stub K1 K2 K3 K4'
	local k i lck=0 long
	long=$(printf '%0200d' 0)
	for k in K1 K2 K3 K4; do entry "$k" "$SENTINEL-$k-$long"; done
	(ulimit -l 64 && LENDK_TEST_PAUSE=3 exec "$LENDK" run -- stub </dev/null 2>"$SB/stderr") &
	local pid=$!
	for ((i = 0; i < 50; i++)); do
		[[ $(compgen -G "$SB/log/pass.*" | wc -l) == 4 ]] && break
		sleep 0.1
	done
	sleep 0.5
	lck=$(sed -n 's/^VmLck:[[:space:]]*\([0-9]*\) kB$/\1/p' "/proc/$pid/status")
	wait "$pid"
	assert_eq "$(<"$SB/stderr")" ""
	((lck * 1024 >= 4 * (${#SENTINEL} + ${#long} + 6))) || { echo "VmLck: $lck kB" >&2; return 1; }
	assert_eq "$(target_var K4)" "$SENTINEL-K4-$long"
}

@test "a call whose memory cannot be locked still runs" {
	map 'stub K1'
	entry K1 "$SENTINEL"
	(ulimit -l 0 && "$LENDK" run -- stub </dev/null 2>"$SB/stderr")
	assert_eq "$(<"$SB/stderr")" ""
	assert_eq "$(target_var K1)" "$SENTINEL"
}
