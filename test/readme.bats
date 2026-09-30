#!/usr/bin/env bats
# FR37 and AC5: the README covers every topic, and its quick start runs as written on a fresh HOME with
# Debian's skel files, real pass and a scratch GnuPG key and store.
# shellcheck disable=SC2016,SC2088

setup() {
	load helpers/common
	load helpers/gpg
	sandbox
	README=$ROOT/README.md
}

teardown() {
	gpg_teardown
}

# quickstart: the commands between the README's quickstart markers, one per line.
quickstart() {
	sed -n '/^<!-- quickstart -->$/,/^<!-- quickstart -->$/p' "$README" | grep -v -e '^<!--' -e '^```'
}

@test "FR37: the README covers every topic" {
	local topic
	for topic in '<!-- quickstart -->' 'Install only from this repository' 'npm and crates.io' \
		'lend init sh >> ~/.zshenv' 'lend init zsh >> ~/.zshrc' 'lend init systemd >' '~/.zprofile' \
		'It does not protect against' 's2k-count 8388608' 'gpg --passwd' 'default-cache-ttl' 'max-cache-ttl' \
		'gpgconf --reload gpg-agent' '/home/alice/.local/bin/lend run -- ' 'cron' 'systemd unit' 'MCP' \
		"'!lend run -- gh auth git-credential'" 'gh auth setup-git' 'npx' 'uv run' \
		'  reserved commands: ' '  lend-missing (127): ' '## For AI agents' '`lend: CLASS:` line' \
		'`locked`, `timeout` or `canceled`, stop and ask' 'Never run `pass`, `lend add`, `lend rm`, or `lend run` with key names, and never print the environment'; do
		grep -qF -e "$topic" "$README" || { echo "README lacks: $topic" >&2; return 1; }
	done
	assert_eq "$(quickstart | wc -l)" 5
}

@test "FR37: the credential helper snippet leaves only lend's helper after none, or after gh's two" {
	require git
	local snippet host want
	snippet=$(sed -n '/^### Git credential helper$/,/^###/p' "$README" | sed -n '/^```$/,/^```$/p' | sed '1d;$d')
	want=$'\n!lend run -- gh auth git-credential'
	cd "$HOME"
	bash -c "$snippet"
	for host in github.com gist.github.com; do
		assert_eq "$(git config --global --get-all "credential.https://$host.helper")" "$want"
	done
	for host in github.com gist.github.com; do
		git config --global --replace-all "credential.https://$host.helper" ''
		git config --global --add "credential.https://$host.helper" '!/usr/bin/gh auth git-credential'
	done
	bash -c "$snippet"
	for host in github.com gist.github.com; do
		assert_eq "$(git config --global --get-all "credential.https://$host.helper")" "$want"
	done
}

@test "AC5: the README's quick start runs as written and gh then receives GH_TOKEN" {
	require git
	require make
	gpg_setup
	local sys=$HOME/bin src=$SB/lend login_path cmds
	mkdir -p "$sys" "$src/bin"
	ln -s "$FIXTURES/stub-target" "$sys/gh"
	cp "$FIXTURES/profile" "$HOME/.profile"
	cp "$FIXTURES/bashrc" "$HOME/.bashrc"
	cp "$ROOT/Makefile" "$ROOT/LICENSE" "$README" "$src/"
	cp "$LEND" "$src/bin/"
	git -C "$src" init -q
	git -C "$src" add -A
	git -C "$src" -c user.name=test -c user.email=test commit -qm src
	login_path=$sys:${BASH%/*}:/usr/bin:/bin
	mapfile -t cmds < <(quickstart)
	[[ ${cmds[0]} == 'git clone https://github.com/v-bonilla/lend '* ]]
	cmds[0]=${cmds[0]/https:\/\/github.com\/v-bonilla\/lend/$(printf %q "$src")}
	assert_eq "${cmds[2]}" 'exec bash -l'
	# login CMD...: CMD in $HOME in an environment built from scratch, as a login would start it.
	login() {
		(cd "$HOME" && env -i HOME="$HOME" PATH="$login_path" TERM=dumb STUB_LOG="$STUB_LOG" \
			GNUPGHOME="$GNUPGHOME" PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" "$@")
	}
	login bash -c "${cmds[0]}" >/dev/null
	login bash -c "${cmds[1]}"
	printf '%s\n%s\n' "$SENTINEL" "$SENTINEL" | login bash -lc "${cmds[3]}" >/dev/null
	login bash -lc "${cmds[4]}" </dev/null >/dev/null
	[[ -f $PASSWORD_STORE_DIR/env/GH_TOKEN.gpg ]]
	gpg_prime GH_TOKEN
	login bash -lc gh </dev/null
	local logs=("$SB"/log/target.*)
	assert_eq "${#logs[@]}" 1
	assert_eq "$(tr '\0' '\n' <"${logs[0]}/env" | sed -n 's/^GH_TOKEN=//p')" "$SENTINEL"
}
