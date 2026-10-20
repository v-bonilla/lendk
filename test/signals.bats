#!/usr/bin/env bats
# No process of a call outlives it, and the backend never takes the terminal.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034

setup() {
	load helpers/common
	load helpers/pty
	sandbox
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	export LENDK_SHIMS=$SB/shims
	mkdir -p "$LENDK_SHIMS" "$HOME/.config/lendk" && chmod 700 "$LENDK_SHIMS" "$HOME/.config/lendk"
	printf 'stub K1\n' >"$HOME/.config/lendk/map"
	chmod 600 "$HOME/.config/lendk/map"
	printf 'value-1\n' >"$SB/store/env/K1.gpg"
}

# start_lendk MODE: start lendk run -- stub in its own process group with the backend in MODE, and
# return once the backend and its child run; lpid is lendk's PID and group.
start_lendk() {
	local i
	printf '%s\n' "$1" >"$SB/store/env/K1.mode"
	set -m
	LENDK_TEST_FAMILY=$SENTINEL "$LENDK" run -- stub </dev/null >/dev/null 2>"$SB/stderr" &
	lpid=$!
	set +m
	for ((i = 0; i < 50; i++)); do
		[[ -f $SB/log/pids && $(wc -l <"$SB/log/pids") -ge 2 ]] && return 0
		sleep 0.1
	done
	echo "the backend did not start" >&2
	return 1
}

# stop_lendk SIGNAL TARGET: send SIGNAL to TARGET, then everything is gone within 2 s and lendk
# exited with no stderr line.
stop_lendk() {
	kill "-$1" -- "$2"
	none_within 2
	wait "$lpid" 2>/dev/null || true
	assert_eq "$(<"$SB/stderr")" ""
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
	assert_eq "$(ls -A "$TMPDIR")" ""
}

@test "TERM, INT or HUP to lendk leaves no backend, child or watchdog behind" {
	local sig mode
	for mode in hang stubborn; do
		for sig in TERM INT HUP; do
			rm -f "$SB/log/pids"
			start_lendk "$mode"
			stop_lendk "$sig" "$lpid"
		done
	done
}

@test "TERM or KILL to lendk's process group leaves no backend, child or watchdog behind" {
	local sig mode
	for mode in hang stubborn; do
		for sig in TERM KILL; do
			rm -f "$SB/log/pids"
			start_lendk "$mode"
			kill "-$sig" -- "-$lpid"
			none_within 2
			wait "$lpid" 2>/dev/null || true
		done
	done
}

@test "after expiry and after exec, nothing of the call is left" {
	local mode
	for mode in hang stubborn; do
		rm -f "$SB/log/pids"
		printf '%s\n' "$mode" >"$SB/store/env/K1.mode"
		LENDK_TIMEOUT=1 LENDK_TEST_FAMILY=$SENTINEL run_lendk run -- stub
		assert_class timeout 120
		none_within 2
	done
	rm -f "$SB/log/pids" "$SB/store/env/K1.mode"
	LENDK_TEST_FAMILY=$SENTINEL run_lendk run -- stub
	assert_eq "$status" 0
	none_within 1
}

@test "a pipeline neighbor using the terminal runs while the backend works" {
	echo slow >"$SB/store/env/K1.mode"
	in_shell "$LENDK run -- stub | { sleep 0.3; stty -echo; stty echo; echo neighbor-done; }" @3 exit
	assert_line "$output" neighbor-done
	refute_contains "$output" Stopped
}

@test "lendk in a background job gives timeout and leaves the shell's terminal alone" {
	echo tty >"$SB/store/env/K1.mode"
	in_shell "LENDK_TIMEOUT=1 $LENDK run -- stub & wait \$!; echo rc=\$?" @4 "echo alive" @1 exit
	assert_line "$output" rc=120
	assert_line "$output" alive
	refute_contains "$output" Stopped
	[[ $output == *"lendk: timeout: env/K1: gpg did not finish within 1 s."* ]]
}

@test "a signal before lendk records the job's PID leaves nothing behind" {
	local sig
	for sig in TERM KILL; do
		rm -f "$SB/log/pids"
		# LENDK_TEST_AT=job pauses right after lendk starts the backend.
		LENDK_TEST_PAUSE=3 LENDK_TEST_AT=job start_lendk stubborn
		kill "-$sig" -- "-$lpid"
		none_within 2
		wait "$lpid" 2>/dev/null || true
	done
}

@test "in a command substitution, which cannot take the terminal, a configured loopback prompt gives locked without prompting" {
	echo tty >"$SB/store/env/K1.mode"
	in_shell "export PASSWORD_STORE_GPG_OPTS='--pinentry-mode loopback'" "x=\$($LENDK run -- stub); echo rc=\$?" @2 exit
	assert_line "$output" rc=120
	[[ $output == *"lendk: locked: env/K1 needs the gpg passphrase and this call cannot prompt. Ask the user to run 'lendk unlock K1' in a terminal, then retry."* ]]
	grep -qx -- '--pinentry-mode loopback --status-fd 9 --pinentry-mode error' < <(tr '\0' '\n' <"$(compgen -G "$SB/log/pass.*")/env" | sed -n 's/^PASSWORD_STORE_GPG_OPTS=//p')
}

@test "in a command substitution without loopback configured, the backend may still prompt through pinentry" {
	in_shell "x=\$($LENDK run -- stub); echo rc=\$?" @2 exit
	assert_line "$output" rc=0
	grep -qx -- '--status-fd 9' < <(tr '\0' '\n' <"$(compgen -G "$SB/log/pass.*")/env" | sed -n 's/^PASSWORD_STORE_GPG_OPTS=//p')
}

@test "a backend stopped on the terminal gives timeout within the bound, leaves nothing, and its files are private under umask 000" {
	local listing ms
	echo tty >"$SB/store/env/K1.mode"
	# ms: milliseconds from /proc/uptime, which busybox's date, lacking %N, cannot give.
	printf '#!/bin/sh\nif [ -r /proc/uptime ]; then read -r u _ </proc/uptime; c=${u#*.}; echo $((${u%%.*} * 1000 + ${c#0} * 10)); else date +%%s%%3N; fi\n' >"$SB/bin/ms"
	chmod +x "$SB/bin/ms"
	in_shell "umask 000; t=\$(ms); LENDK_TIMEOUT=2 $(printf %q "$LENDK") run -- stub; echo rc=\$? ms=\$((\$(ms) - t))" @5 exit
	ms=$(grep -o 'rc=120 ms=[0-9]*' <<<"$output") || { echo "$output" >&2; return 1; }
	ms=${ms#*ms=}
	((ms >= 2000 && ms < 3700)) || { echo "took $ms ms" >&2; return 1; }
	assert_line "$output" "lendk: timeout: env/K1: gpg did not finish within 2 s. Retry; a hardware token may need a touch, or raise LENDK_TIMEOUT."
	refute_contains "$output" Stopped
	none_within 1
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
	assert_eq "$(ls -A "$TMPDIR")" ""
	listing=$(cat "$SB"/log/pass.*/tmp-modes)
	[[ $listing == *" err.K1"* && $listing == *" status.K1"* ]] || { echo "$listing" >&2; return 1; }
	assert_eq "$(grep -E '^-' <<<"$listing" | grep -v '^-rw------- ')" ""
}
