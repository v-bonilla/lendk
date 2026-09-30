#!/usr/bin/env bats
# FR17: no process of a call outlives it, and the backend takes the terminal only for a loopback prompt.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034

setup() {
	load helpers/common
	load helpers/pty
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	export LEND_SHIMS=$SB/shims
	mkdir -p "$LEND_SHIMS" "$HOME/.config/lend" && chmod 700 "$LEND_SHIMS" "$HOME/.config/lend"
	printf 'stub K1\n' >"$HOME/.config/lend/map"
	chmod 600 "$HOME/.config/lend/map"
	printf 'value-1\n' >"$SB/store/env/K1.gpg"
}

# start_lend MODE: start lend run -- stub in its own process group with the backend in MODE, and
# return once the backend and its child run; lpid is lend's PID and group.
start_lend() {
	local i
	printf '%s\n' "$1" >"$SB/store/env/K1.mode"
	set -m
	LEND_TEST_FAMILY=$SENTINEL "$LEND" run -- stub </dev/null >/dev/null 2>"$SB/stderr" &
	lpid=$!
	set +m
	for ((i = 0; i < 50; i++)); do
		[[ -f $SB/log/pids && $(wc -l <"$SB/log/pids") -ge 2 ]] && return 0
		sleep 0.1
	done
	echo "the backend did not start" >&2
	return 1
}

# stop_lend SIGNAL TARGET: send SIGNAL to TARGET, then everything is gone within 2 s and lend
# exited with no stderr line.
stop_lend() {
	kill "-$1" -- "$2"
	none_within 2
	wait "$lpid" 2>/dev/null || true
	assert_eq "$(<"$SB/stderr")" ""
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
	assert_eq "$(ls -A "$TMPDIR")" ""
}

@test "FR17: TERM, INT or HUP to lend leaves no backend, child or watchdog behind" {
	local sig mode
	for mode in hang stubborn; do
		for sig in TERM INT HUP; do
			rm -f "$SB/log/pids"
			start_lend "$mode"
			stop_lend "$sig" "$lpid"
		done
	done
}

@test "FR17: TERM or KILL to lend's process group leaves no backend, child or watchdog behind" {
	local sig mode
	for mode in hang stubborn; do
		for sig in TERM KILL; do
			rm -f "$SB/log/pids"
			start_lend "$mode"
			kill "-$sig" -- "-$lpid"
			none_within 2
			wait "$lpid" 2>/dev/null || true
		done
	done
}

@test "FR17: after expiry and after exec, nothing of the call is left" {
	local mode
	for mode in hang stubborn; do
		rm -f "$SB/log/pids"
		printf '%s\n' "$mode" >"$SB/store/env/K1.mode"
		LEND_TIMEOUT=1 LEND_TEST_FAMILY=$SENTINEL run_lend run -- stub
		assert_class timeout 120
		none_within 2
	done
	rm -f "$SB/log/pids" "$SB/store/env/K1.mode"
	LEND_TEST_FAMILY=$SENTINEL run_lend run -- stub
	assert_eq "$status" 0
	none_within 1
}

@test "FR17: a loopback prompt gets the terminal once and its typed line; the target gets the line" {
	echo tty >"$SB/store/env/K1.mode"
	in_shell "$LEND run -- stub; echo rc=\$?" @2 typed-secret @1 exit
	assert_line "$output" rc=0
	refute_contains "$output" Stopped
	refute_contains "$output" typed-secret
	local logs=("$SB"/log/target.*) conts=("$SB"/log/pass.*/conts)
	tr '\0' '\n' <"${logs[0]}/env" | grep -qx K1=typed-secret
	assert_eq "$(<"${conts[0]}")" cont
}

@test "FR17: Ctrl-C at a loopback prompt gives canceled" {
	echo tty >"$SB/store/env/K1.mode"
	in_shell "$LEND run -- stub; echo rc=\$?" @2 ^C @1 exit
	assert_line "$output" "lend: canceled: passphrase entry for env/K1 was canceled. Run the command again to retry."
	assert_line "$output" rc=120
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
}

@test "FR17: a pipeline neighbor using the terminal runs while the backend works" {
	echo slow >"$SB/store/env/K1.mode"
	in_shell "$LEND run -- stub | { sleep 0.3; stty -echo; stty echo; echo neighbor-done; }" @3 exit
	assert_line "$output" neighbor-done
	refute_contains "$output" Stopped
}

@test "FR17: lend in a background job gives timeout and leaves the shell's terminal alone" {
	echo tty >"$SB/store/env/K1.mode"
	in_shell "LEND_TIMEOUT=1 $LEND run -- stub & wait \$!; echo rc=\$?" @4 "echo alive" @1 exit
	assert_line "$output" rc=120
	assert_line "$output" alive
	refute_contains "$output" Stopped
	[[ $output == *"lend: timeout: env/K1: gpg did not finish within 1 s."* ]]
}

@test "FR17: with stderr redirected to a file, a loopback prompt still gets the terminal" {
	echo tty >"$SB/store/env/K1.mode"
	in_shell "$LEND run -- stub 2>$SB/err; echo rc=\$?" @2 typed-secret @1 exit
	assert_line "$output" rc=0
	refute_contains "$output" typed-secret
	assert_eq "$(<"$SB/err")" ""
	local logs=("$SB"/log/target.*)
	tr '\0' '\n' <"${logs[0]}/env" | grep -qx K1=typed-secret
}

@test "FR17: a signal before lend records the job's PID leaves nothing behind" {
	local sig
	for sig in TERM KILL; do
		rm -f "$SB/log/pids"
		LEND_TEST_PAUSE=3 start_lend stubborn
		kill "-$sig" -- "-$lpid"
		none_within 2
		wait "$lpid" 2>/dev/null || true
	done
}

@test "FR17: in a command substitution, which cannot take the terminal, a configured loopback prompt gives locked without prompting" {
	echo tty >"$SB/store/env/K1.mode"
	in_shell "export PASSWORD_STORE_GPG_OPTS='--pinentry-mode loopback'" "x=\$($LEND run -- stub); echo rc=\$?" @2 exit
	assert_line "$output" rc=120
	[[ $output == *"lend: locked: env/K1 needs the gpg passphrase and this call cannot prompt. Ask the user to run 'lend unlock K1' in a terminal, then retry."* ]]
	grep -qx -- '--pinentry-mode loopback --status-fd 9 --pinentry-mode error' < <(tr '\0' '\n' <"$(compgen -G "$SB/log/pass.*")/env" | sed -n 's/^PASSWORD_STORE_GPG_OPTS=//p')
}

@test "FR17: in a command substitution without loopback configured, the backend may still prompt through pinentry" {
	in_shell "x=\$($LEND run -- stub); echo rc=\$?" @2 exit
	assert_line "$output" rc=0
	grep -qx -- '--status-fd 9' < <(tr '\0' '\n' <"$(compgen -G "$SB/log/pass.*")/env" | sed -n 's/^PASSWORD_STORE_GPG_OPTS=//p')
}

@test "FR17: a pipeline neighbor that reads the terminal during a loopback prompt resumes afterwards" {
	echo tty >"$SB/store/env/K1.mode"
	in_shell "$LEND run -- stub | { sleep 0.5; IFS= read -r x </dev/tty; echo neighbor=\$x; }" @2 typed-secret @1.5 neighbor-line @1 exit
	assert_line "$output" neighbor=neighbor-line
	refute_contains "$output" Stopped
}

@test "FR17: under umask 000, lend's files for the backend phase are private" {
	local listing
	echo tty >"$SB/store/env/K1.mode"
	in_shell "umask 000; $LEND run -- stub" @2 typed-secret @1 exit
	echo stubborn >"$SB/store/env/K1.mode"
	(umask 000 && LEND_TIMEOUT=1 "$LEND" run -- stub </dev/null 2>/dev/null) || true
	listing=$(cat "$SB"/log/pass.*/tmp-modes)
	[[ $listing == *" stopped"* && $listing == *" timeout"* ]] || { echo "$listing" >&2; return 1; }
	assert_eq "$(grep -E '^-' <<<"$listing" | grep -v '^-rw------- ')" ""
}
