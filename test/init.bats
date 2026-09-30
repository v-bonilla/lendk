#!/usr/bin/env bats
# lend init: the PRD 4.3 blocks (FR35) and the shim directory check (FR28).
# shellcheck disable=SC2016

setup() {
	load helpers/common
	sandbox
	export LEND_SHIMS=$SB/shims
	SHIMS=$LEND_SHIMS
}

# block SHELL: write lend init SHELL's output to $SB/block.
block() {
	run_lend init "$1"
	assert_eq "$status" 0
	assert_eq "$stderr" ""
	printf '%s\n' "$output" >"$SB/block"
}

@test "FR35: init sh moves the shim directory to the front of PATH once, keeping every other entry" {
	block sh
	assert_eq "${output%%$'\n'*}" '# >>> lend >>>'
	assert_eq "${output##*$'\n'}" '# <<< lend <<<'
	assert_line "$output" "PATH='$SHIMS'\$lend_p; export PATH"
	run env -i PATH="/a::$SHIMS:/b:$SHIMS:/usr/bin:/bin" sh -c '. "$1"; . "$1"; printf "%s|%s" "$PATH" "${lend_p-unset}"' sh "$SB/block"
	assert_eq "$output" "$SHIMS:/a::/b:/usr/bin:/bin|unset"
	run env -i /bin/sh -c 'PATH=; . "$1"; printf "%s" "$PATH"' sh "$SB/block"
	assert_eq "$output" "$SHIMS"
}

@test "FR35: init reads no map and holds the absolute shim directory, quotes escaped" {
	mkdir -p "$HOME/.config/lend"
	printf 'broken line !\n' >"$HOME/.config/lend/map"
	chmod 777 "$HOME/.config/lend/map"
	mkdir "$SB/it's"

	LEND_SHIMS="$SB/it's/shims/" block sh
	assert_line "$output" "PATH='$SB/it'\\''s/shims'\$lend_p; export PATH"
	run env -i PATH=/usr/bin:/bin sh -c '. "$1"; printf "%s" "$PATH"' sh "$SB/block"
	assert_eq "$output" "$SB/it's/shims:/usr/bin:/bin"
}

@test "FR35: the bash hook registers once when its block runs twice, and repeats the move with hash -r" {
	block bash
	run env -i PATH=/usr/bin:/bin PROMPT_COMMAND="echo hi" "$BASH" --norc --noprofile -c '
		. "$1"; . "$1"
		printf "%s\n" "$PROMPT_COMMAND" "$PATH"
		PATH=/x:$PATH
		__lend_path
		printf "%s|%s\n" "$PATH" "$(declare -f __lend_path | grep -c "hash -r")"' bash "$SB/block"
	assert_eq "$output" "__lend_path;echo hi"$'\n'"$SHIMS:/usr/bin:/bin"$'\n'"$SHIMS:/x:/usr/bin:/bin|1"
	run env -i PATH=/usr/bin:/bin "$BASH" --norc --noprofile -c '. "$1"; . "$1"; printf "%s" "$PROMPT_COMMAND"' bash "$SB/block"
	assert_eq "$output" "__lend_path"
}

@test "FR35: the zsh hook registers once when its block runs twice, and repeats the move" {
	require zsh
	block zsh
	run env -i PATH=/usr/bin:/bin zsh -f -c '
		. "$1"; . "$1"
		print -r -- "${(j: :)precmd_functions}|$PATH"
		PATH=/x:$PATH
		for f in $precmd_functions; do $f; done
		print -r -- "$PATH"' zsh "$SB/block"
	assert_eq "$output" "__lend_path|$SHIMS:/usr/bin:/bin"$'\n'"$SHIMS:/x:/usr/bin:/bin"
}

@test "FR35: init systemd prints PATH with the shim directory, then \${PATH}" {
	block systemd
	assert_eq "$output" $'# >>> lend >>>\n'"PATH=$SHIMS:\${PATH}"$'\n# <<< lend <<<'
}

@test "FR35: systemd's environment.d generator puts the shim directory first" {
	require environment-d
	mkdir -p "$HOME/.config/environment.d"
	block systemd
	cp "$SB/block" "$HOME/.config/environment.d/99-lend.conf"
	run env -i HOME="$HOME" PATH=/usr/bin:/bin /usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator
	[[ $'\n'$output == *$'\n'"PATH=$SHIMS:"* ]]
}

@test "FR28: init gives unsafe and prints no code for a shim directory open to others" {
	mkdir -m 700 "$SHIMS"
	block sh
	chmod 770 "$SHIMS"
	run_lend init bash
	assert_eq "$output" ""
	assert_eq "$stderr" "lend: unsafe: $SHIMS is writable by others. Stop and ask the user."
	assert_class unsafe 125
}

@test "FR35: init without one of sh, bash, zsh or systemd is usage" {
	run_lend init
	assert_class usage 2
	run_lend init fish
	assert_eq "$stderr" "lend: usage: init takes one of sh, bash, zsh or systemd, not 'fish'. See: lend --help"
	assert_eq "$output" ""
	run_lend init sh bash
	assert_class usage 2
}

@test "FR35: the zsh block runs under nounset, and init rejects a relative LEND_SHIMS" {
	require zsh
	block zsh
	run env -i PATH=/usr/bin:/bin zsh -f -o nounset -c '. "$1"; . "$1"; print -r -- "${(j: :)precmd_functions}"' zsh "$SB/block"
	assert_eq "$output" "__lend_path"
	LEND_SHIMS=./shims run_lend init sh
	assert_eq "$stderr" "lend: usage: LEND_SHIMS is './shims'; use an absolute path. See: lend --help"
	assert_eq "$output" ""
}
