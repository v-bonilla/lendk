# Pseudo-terminal helpers, loaded after common.bash; both need script(1).
# shellcheck disable=SC2034

# in_pty TEXT: run bash TEXT with a pseudo-terminal as stdin, stdout and stderr; status is TEXT's,
# output the terminal's output with carriage returns removed.
in_pty() {
	require script
	status=0
	output=$(SHELL=$(command -v bash) script -qec "$1" /dev/null </dev/null) || status=$?
	output=${output//$'\r'/}
	output=${output//$'\e[?2004h'/}
	output=${output//$'\e[?2004l'/}
}

# in_shell STEP...: an interactive bash with job control in a pseudo-terminal, typing each STEP as a
# line; a step @N waits N seconds and ^C types Ctrl-C. output is the terminal's output.
in_shell() {
	local step
	require script
	output=$(
		for step in "$@"; do
			case $step in
			@*) sleep "${step#@}" ;;
			^C) printf '\003' ;;
			*) printf '%s\r' "$step" ;;
			esac
		done | SHELL=$(command -v bash) script -qfec "$(command -v bash) --norc --noprofile -i" /dev/null || :
	)
	output=${output//$'\r'/}
	output=${output//$'\e[?2004h'/}
	output=${output//$'\e[?2004l'/}
}
