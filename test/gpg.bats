#!/usr/bin/env bats
# FR18, FR34: real pass and GnuPG with a scratch GnuPG home, a passphrase-protected key and a
# recording pinentry, in both of pass's branches: plain gpg, and gpg2 on PATH, which adds --batch.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034

setup() {
	load helpers/common
	load helpers/pty
	load helpers/gpg
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	export LENDK_SHIMS=$SB/shims
	mkdir -p "$LENDK_SHIMS" "$HOME/.config/lendk" && chmod 700 "$LENDK_SHIMS" "$HOME/.config/lendk"
	printf 'stub K1\n' >"$HOME/.config/lendk/map"
	chmod 600 "$HOME/.config/lendk/map"
	gpg_setup
	gpg_insert K1 "$SENTINEL"
}

teardown() {
	gpg_teardown
}

# branch NAME: pass's branch, plain or gpg2, with a cold cache and fresh recorder logs.
branch() {
	if [[ $1 == gpg2 ]]; then with_gpg2; else without_gpg2; fi
	gpg_cold
	rm -rf "$SB/log" && mkdir "$SB/log"
}

# target_got: the one target call received K1's value.
target_got() {
	local logs=("$SB"/log/target.*)
	assert_eq "${#logs[@]}" 1
	[[ $'\n'$(tr '\0' '\n' <"${logs[0]}/env")$'\n' == *$'\n'"K1=$SENTINEL"$'\n'* ]] ||
		{ echo "the target did not get K1" >&2; return 1; }
}

# recorder_pids: the recorder's PIDs, one per launch.
recorder_pids() { cat "$GNUPGHOME/pinentry.pids" 2>/dev/null || :; }

# bats test_tags=gpg
@test "FR18: (a) a cold non-interactive call gives locked within 2 s and never launches pinentry" {
	local b start
	for b in plain gpg2; do
		branch "$b"
		start=$(now_ms)
		run_lendk run -- stub
		assert_class locked 120
		assert_eq "$stderr" "lendk: locked: env/K1 needs the gpg passphrase and this call cannot prompt. Ask the user to run 'lendk unlock K1' in a terminal, then retry."
		(($(now_ms) - start < 2000))
		assert_eq "$(recorder_pids)" ""
		assert_eq "$(compgen -G "$SB/log/target.*")" ""
	done
}

# bats test_tags=gpg
@test "FR18: (b) after priming through loopback a non-interactive call succeeds" {
	local b
	for b in plain gpg2; do
		branch "$b"
		gpg_prime K1
		run_lendk run -- stub
		assert_eq "$stderr" ""
		assert_eq "$status" 0
		target_got
		assert_eq "$(recorder_pids)" ""
	done
}

# bats test_tags=gpg
@test "FR18: (c) LENDK_PROMPT=allow launches pinentry" {
	local b
	for b in plain gpg2; do
		branch "$b"
		LENDK_PROMPT=allow run_lendk run -- stub
		assert_eq "$stderr" ""
		assert_eq "$status" 0
		target_got
		assert_eq "$(recorder_pids | wc -l)" 1
	done
}

# bats test_tags=gpg
@test "FR18: (d) with stdin piped and stderr a terminal, pinentry gets that terminal as ttyname" {
	local b q
	q=$(printf %q "$SB")
	for b in plain gpg2; do
		branch "$b"
		in_pty "tty >$q/tty; echo | $(printf %q "$LENDK") run -- stub"
		assert_eq "$status" 0
		target_got
		[[ $(<"$SB/tty") == /dev/* ]]
		assert_line "$(<"$GNUPGHOME/pinentry.options")" "ttyname=$(<"$SB/tty")"
	done
}

# bats test_tags=gpg
@test "FR18: (e) Cancel in pinentry gives canceled" {
	local b
	for b in plain gpg2; do
		branch "$b"
		echo cancel >"$GNUPGHOME/pinentry.mode"
		LENDK_PROMPT=allow run_lendk run -- stub
		assert_eq "$stderr" "lendk: canceled: passphrase entry for env/K1 was canceled. Run the command again to retry."
		assert_class canceled 120
		assert_eq "$(compgen -G "$SB/log/target.*")" ""
	done
}

# bats test_tags=gpg
@test "FR18: (f) a pinentry that never answers gives timeout within 4 s and is gone afterwards" {
	local b start p
	for b in plain gpg2; do
		branch "$b"
		echo hang >"$GNUPGHOME/pinentry.mode"
		start=$(now_ms)
		LENDK_PROMPT=allow LENDK_TIMEOUT=2 run_lendk run -- stub
		assert_class timeout 120
		(($(now_ms) - start < 4000))
		p=$(recorder_pids)
		[[ -n $p ]]
		gone_within 2 "$p"
	done
}

# bats test_tags=gpg
@test "FR18: (g) KILL to lendk's process group while pinentry waits leaves no pinentry within 2 s" {
	local b i lpid p
	for b in plain gpg2; do
		branch "$b"
		echo hang >"$GNUPGHOME/pinentry.mode"
		set -m
		LENDK_PROMPT=allow "$LENDK" run -- stub </dev/null >/dev/null 2>"$SB/stderr" &
		lpid=$!
		set +m
		for ((i = 0; i < 100; i++)); do
			p=$(recorder_pids)
			[[ -n $p ]] && break
			sleep 0.1
		done
		[[ -n $p ]]
		kill -KILL -- "-$lpid"
		wait "$lpid" 2>/dev/null || :
		gone_within 2 "$p"
		assert_eq "$(compgen -G "$SB/log/target.*")" ""
	done
}

# bats test_tags=gpg
@test "FR18: (h) with loopback in gpg.conf the passphrase typed into the terminal reaches gpg, and the target gets the value" {
	branch plain
	echo 'pinentry-mode loopback' >"$GNUPGHOME/gpg.conf"
	in_shell "$(printf %q "$LENDK") run -- stub; st=\$?; echo; echo status=\$st" @3 "$GPG_PASS" @3 exit
	assert_line "$output" "status=0"
	target_got
	assert_eq "$(recorder_pids)" ""
}

# bats test_tags=gpg
@test "FR18: (i) with loopback in gpg.conf, a call in a command substitution gives locked and shows no prompt" {
	branch plain
	echo 'pinentry-mode loopback' >"$GNUPGHOME/gpg.conf"
	in_shell "x=\$($(printf %q "$LENDK") run -- stub); echo rc=\$?" @3 exit
	assert_line "$output" rc=120
	[[ $output == *"lendk: locked: env/K1 needs the gpg passphrase and this call cannot prompt. Ask the user to run 'lendk unlock K1' in a terminal, then retry."* ]]
	refute_contains "$output" "Enter passphrase"
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
	assert_eq "$(recorder_pids)" ""
}

# bats test_tags=gpg
@test "FR34: unlock with a pinentry primes the cache for non-interactive calls" {
	local b
	for b in plain gpg2; do
		branch "$b"
		LENDK_PROMPT=allow run_lendk unlock
		assert_eq "$stderr" ""
		assert_eq "$output" unlocked
		assert_eq "$status" 0
		refute_contains "$output" "$SENTINEL"
		run_lendk unlock K1
		assert_eq "$output" unlocked
		run_lendk run -- stub
		assert_eq "$status" 0
		target_got
		assert_eq "$(recorder_pids | wc -l)" 1
	done
}

# bats test_tags=gpg
@test "FR34: unlock without a terminal is a probe that gives locked on a cold cache" {
	local b
	for b in plain gpg2; do
		branch "$b"
		run_lendk unlock K1
		assert_eq "$output" ""
		assert_class locked 120
		assert_eq "$(recorder_pids)" ""
	done
}
