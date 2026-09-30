#!/usr/bin/env bats
# The decrypt path: order, values, export timing, the caller's umask and descriptors, and where values go.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
	load helpers/common
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	export LEND_SHIMS=$SB/shims
	mkdir -p "$LEND_SHIMS" && chmod 700 "$LEND_SHIMS"
}

map() {
	mkdir -p "$HOME/.config/lend" && chmod 700 "$HOME/.config/lend"
	printf '%s\n' "$@" >"$HOME/.config/lend/map"
	chmod 600 "$HOME/.config/lend/map"
}

# entry KEY VALUE: store VALUE, a newline and a second line as KEY's entry.
entry() { printf '%s\nsecond line\n' "$2" >"$SB/store/env/$1.gpg"; }

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

@test "FR3: every missing key is listed before any decrypt, and the command does not run" {
	map 'stub K1 K2 K3'
	entry K2 "$SENTINEL"
	run_lend run -- stub
	assert_eq "$stderr" "lend: missing-key: env/K1 is not in the store. Stop and ask the user.
lend: missing-key: env/K3 is not in the store. Stop and ask the user."
	assert_class missing-key 125
	assert_eq "$(pass_logs)" ""
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
}

@test "FR3: the command resolves before anything is decrypted" {
	map 'nothere K1'
	entry K1 "$SENTINEL"
	run_lend run -- nothere
	assert_class not-found 127
	assert_eq "$(pass_logs)" ""
}

@test "FR3: a failed decrypt stops the call with gpg's last line, and the command does not run" {
	map 'stub K1 K2'
	entry K1 one
	entry K2 two
	printf '#!/bin/sh\necho "gpg: first" >&2\necho "gpg: decryption failed: No secret key" >&2\nexit 2\n' >"$SB/bin/failpass"
	chmod 755 "$SB/bin/failpass"
	rm "$SB/bin/pass"
	ln -s "$SB/bin/failpass" "$SB/bin/pass"
	run_lend run -- stub
	assert_eq "$stderr" "lend: decrypt: env/K1: gpg says: gpg: decryption failed: No secret key. Ask the user to run 'lend unlock K1' in a terminal, then retry."
	assert_class decrypt 125
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
	assert_eq "$(ls -A "$TMPDIR")" ""
}

@test "FR4: a later backend call sees no key read earlier; all keys reach the target" {
	map 'stub K1 K2'
	entry K1 "$SENTINEL-1"
	entry K2 "$SENTINEL-2"
	run_lend run -- stub
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

@test "FR4, FR20: under strace the sentinel appears only in the target's execve, and there only in its environment" {
	require strace
	map 'tgt K1 K2'
	entry K1 "$SENTINEL-1"
	entry K2 "$SENTINEL-2"
	printf '#!/bin/sh\nexit 0\n' >"$SB/bin/tgt"
	chmod 755 "$SB/bin/tgt"
	strace -f --seccomp-bpf -v -s 4096 -e trace=execve -o "$SB/trace" "$LEND" run -- tgt </dev/null 2>"$SB/stderr"
	assert_eq "$(<"$SB/stderr")" ""
	local hits
	hits=$(grep -F -- "$SENTINEL" "$SB/trace")
	assert_eq "$(grep -c . <<<"$hits")" 1
	[[ $hits == *"execve(\"$SB/bin/tgt\", [\"tgt\"], ["* ]]
	[[ ${hits%%], [*} != *"$SENTINEL"* ]]
}

@test "FR7: the target gets the caller's umask and descriptors, and lend's files are private, under umask 000 and 022" {
	map 'tgt K1'
	entry K1 "$SENTINEL"
	printf '#!/bin/sh\numask >"$STUB_LOG/umask"\n{ echo open >&7; } 2>/dev/null\n' >"$SB/bin/tgt"
	chmod 755 "$SB/bin/tgt"
	local mask modes
	for mask in 000 022; do
		rm -rf "$SB/log" && mkdir "$SB/log"
		(umask "$mask" && exec 7>"$SB/fd7" && "$LEND" run -- tgt </dev/null 2>"$SB/stderr")
		assert_eq "$(<"$SB/stderr")" ""
		assert_eq "$(<"$SB/log/umask")" "0$mask"
		assert_eq "$(<"$SB/fd7")" open
		modes=$(cut -c1-10 "$(pass_logs)/stderr-modes")
		assert_eq "$modes" $'drwx------\n-rw-------'
	done
}

@test "FR10: the value is the first line without its newline, spaces and glob characters kept" {
	map 'stub K1'
	printf '  a * b\\n  \nsecond\n' >"$SB/store/env/K1.gpg"
	run_lend run -- stub
	assert_eq "$status" 0
	assert_eq "$(target_var K1)" '  a * b\n  '
}

@test "FR10: an empty first line or an empty entry is missing-key" {
	map 'stub K1'
	printf '\nsecond\n' >"$SB/store/env/K1.gpg"
	run_lend run -- stub
	assert_eq "$stderr" "lend: missing-key: env/K1 has an empty first line. Stop and ask the user."
	assert_class missing-key 125
	: >"$SB/store/env/K1.gpg"
	LEND_PROMPT=allow run_lend run -- stub
	assert_eq "$stderr" "lend: missing-key: env/K1 has an empty first line. Set it: pass edit env/K1"
	assert_class missing-key 125
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
	assert_eq "$(ls -A "$TMPDIR")" ""
}

@test "FR10: a 200 kB first line reads in under 1 s" {
	map 'stub K1'
	: >"$SB/store/env/K1.gpg"
	echo big >"$SB/store/env/K1.mode"
	# The kernel refuses a 200 kB environment string at exec, so the read is timed on its own.
	run lend-fn eval 'load_env; declare -A lend_env=([PATH]=$PATH [HOME]=$HOME [PASSWORD_STORE_DIR]=$PASSWORD_STORE_DIR) lend_values=()
		lend_tmp=$(mktemp -d) lend_gpg_tty=; TIMEFORMAT=%R; time read_values K1; echo "${#lend_values[K1]}"' </dev/null
	assert_eq "${lines[1]}" 200000
	[[ ${lines[0]%%.*} == 0 ]] || { echo "took ${lines[0]} s" >&2; return 1; }
}

@test "FR20: the sentinel reaches no output, file or helper, also under bash -x and an exported SHELLOPTS=xtrace" {
	map 'stub K1' 'nest K2'
	entry K1 "$SENTINEL"
	entry K2 "$SENTINEL-2"
	run_lend run -- stub
	assert_eq "$status" 0
	refute_contains "$output$stderr" "$SENTINEL"
	no_sentinel
	rm -rf "$SB/log" && mkdir "$SB/log"
	bash -x "$LEND" run -- stub </dev/null >"$SB/out" 2>"$SB/stderr"
	refute_contains "$(<"$SB/out")$(<"$SB/stderr")" "$SENTINEL"
	[[ -s $SB/stderr ]]
	no_sentinel
	rm -rf "$SB/log" && mkdir "$SB/log"
	# A nested call under xtrace: the outer target's key is preset for the inner lend.
	printf '#!/bin/sh\nexec %q run -- stub\n' "$LEND" >"$SB/bin/nest"
	chmod 755 "$SB/bin/nest"
	env SHELLOPTS=xtrace "$LEND" run K2 -- nest </dev/null >"$SB/out" 2>"$SB/stderr"
	refute_contains "$(<"$SB/out")$(<"$SB/stderr")" "$SENTINEL"
	[[ -s $SB/stderr ]]
	no_sentinel
	assert_eq "$(target_var K2)" "$SENTINEL-2"
}

@test "FR21: lend leaves stdin to the target, and the backend's stdin is /dev/null" {
	map 'tgt K1'
	entry K1 "$SENTINEL"
	printf '#!/bin/sh\ncat >"$STUB_LOG/stdin"\n' >"$SB/bin/tgt"
	chmod 755 "$SB/bin/tgt"
	printf 'line one\nline two\n' | "$LEND" run -- tgt 2>"$SB/stderr"
	assert_eq "$(<"$SB/stderr")" ""
	assert_eq "$(<"$SB/log/stdin")" $'line one\nline two'
	assert_eq "$(<"$(pass_logs)/stdin")" /dev/null
}
