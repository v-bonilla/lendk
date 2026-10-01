# Pseudo-terminal helpers, loaded after common.bash; both need script(1).
# shellcheck disable=SC2034

# pty_script FLUSH CMD...: CMD under script(1) in a new pseudo-terminal, exiting with CMD's status;
# FLUSH f writes the output as it comes. util-linux takes a command line, BSD takes the words.
pty_script() {
	local bash
	bash=$(command -v bash)
	if script -V >/dev/null 2>&1; then
		SHELL=$bash script -q"$1"ec "$(printf '%q ' "$bash" "${@:3}")" /dev/null
	else
		SHELL=$bash script -qe"${1:+F}" /dev/null "$bash" "${@:3}"
	fi
}

# in_pty TEXT: run bash TEXT with a pseudo-terminal as stdin, stdout and stderr; status is TEXT's,
# output the terminal's output with carriage returns removed.
in_pty() {
	require script
	status=0
	output=$(pty_script '' bash -c "$1" </dev/null) || status=$?
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
		done | pty_script f bash --norc --noprofile -i || :
	)
	output=${output//$'\r'/}
	output=${output//$'\e[?2004h'/}
	output=${output//$'\e[?2004l'/}
}
