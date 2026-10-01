#!/usr/bin/env bats
# FR14, FR15: interactivity, the backend's options and GPG_TTY, and classification of backend failures.
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

# pass_var NAME: NAME=VALUE from the one fake pass call's environment, or nothing.
pass_var() {
	local logs=("$SB"/log/pass.*) e
	assert_eq "${#logs[@]}" 1
	while IFS= read -r -d '' e; do [[ ${e%%=*} == "$1" ]] && printf '%s\n' "$e"; done <"${logs[0]}/env"
	return 0
}

@test "FR14: the matrix of terminal stdin and stderr and LENDK_PROMPT sets the backend options" {
	local in err p cmd want
	export PASSWORD_STORE_GPG_OPTS='--user-a --user-b'
	for in in tty pipe; do
		for err in tty file; do
			for p in auto never allow bad; do
				rm -rf "$SB/log" && mkdir "$SB/log"
				cmd="LENDK_PROMPT=$p $(printf %q "$LENDK") run -- stub"
				[[ $in == pipe ]] && cmd="echo | $cmd"
				[[ $err == file ]] && cmd="$cmd 2>$(printf %q "$SB/err")"
				in_pty "$cmd"
				if [[ $p == bad ]]; then
					assert_eq "$status" 2
					assert_eq "$(compgen -G "$SB/log/pass.*")" ""
					continue
				fi
				assert_eq "$status" 0
				want=1
				[[ $p == never || ($p == auto && $in == pipe && $err == file) ]] && want=0
				if ((want)); then
					assert_eq "$(pass_var PASSWORD_STORE_GPG_OPTS)" "PASSWORD_STORE_GPG_OPTS=--user-a --user-b --status-fd 9"
				else
					assert_eq "$(pass_var PASSWORD_STORE_GPG_OPTS)" "PASSWORD_STORE_GPG_OPTS=--user-a --user-b --status-fd 9 --pinentry-mode error"
				fi
			done
		done
	done
}

@test "FR14: gpg's status code, not its text, classifies failures, per interactivity" {
	local mode prompt want
	for mode in locked cancel fail; do
		echo "$mode" >"$SB/store/env/K1.mode"
		for prompt in never allow; do
			case $prompt:$mode in
			never:locked | never:cancel) want=locked ;;
			allow:cancel) want=canceled ;;
			*) want=decrypt ;;
			esac
			LENDK_PROMPT=$prompt run_lendk run -- stub
			assert_eq "$(wc -l <"$SB/stderr")" 1
			assert_class "$want" "$( [[ $want == decrypt ]] && echo 125 || echo 120)"
			[[ $want != decrypt ]] || assert_line "$stderr" "lendk: decrypt: env/K1: gpg says: decryption failed: $mode. $(
				[[ $prompt == allow ]] && echo 'See gpg'"'"'s error: lendk unlock K1' || echo "Ask the user to run 'lendk unlock K1' in a terminal, then retry.")"
			assert_eq "$(ls -A "$TMPDIR")" ""
		done
	done
	echo locked >"$SB/store/env/K1.mode"
	LENDK_PROMPT=never run_lendk run -- stub
	assert_eq "$stderr" "lendk: locked: env/K1 needs the gpg passphrase and this call cannot prompt. Ask the user to run 'lendk unlock K1' in a terminal, then retry."
	echo cancel >"$SB/store/env/K1.mode"
	LENDK_PROMPT=allow run_lendk run -- stub
	assert_eq "$stderr" "lendk: canceled: passphrase entry for env/K1 was canceled. Run the command again to retry."
}

@test "FR15: an interactive backend gets stdin's terminal as GPG_TTY, else stderr's; the target never does" {
	local q
	q=$(printf %q "$SB")
	in_pty "tty >$q/tty; $(printf %q "$LENDK") run -- stub"
	assert_eq "$status" 0
	assert_eq "$(pass_var GPG_TTY)" "GPG_TTY=$(<"$SB/tty")"
	[[ $(<"$SB/tty") == /dev/* ]]
	local logs=("$SB"/log/target.*)
	[[ $'\n'$(tr '\0' '\n' <"${logs[0]}/env") != *$'\n'GPG_TTY=* ]]
	rm -rf "$SB/log" && mkdir "$SB/log"
	in_pty "tty >$q/tty; echo | $(printf %q "$LENDK") run -- stub"
	assert_eq "$status" 0
	assert_eq "$(pass_var GPG_TTY)" "GPG_TTY=$(<"$SB/tty")"
}

@test "FR15: a caller GPG_TTY naming a character device stays, any other is replaced, and non-interactive calls add none" {
	local q
	q=$(printf %q "$SB")
	in_pty "tty >$q/tty; GPG_TTY=/dev/null $(printf %q "$LENDK") run -- stub"
	assert_eq "$(pass_var GPG_TTY)" "GPG_TTY=/dev/null"
	rm -rf "$SB/log" && mkdir "$SB/log"
	in_pty "tty >$q/tty; GPG_TTY=$q/nothere $(printf %q "$LENDK") run -- stub"
	assert_eq "$(pass_var GPG_TTY)" "GPG_TTY=$(<"$SB/tty")"
	rm -rf "$SB/log" && mkdir "$SB/log"
	run_lendk run -- stub
	assert_eq "$status" 0
	assert_eq "$(pass_var GPG_TTY)" ""
}
