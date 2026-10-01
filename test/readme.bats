#!/usr/bin/env bats
# FR37 and AC5: the README covers every topic, and its quick start runs as written on a fresh HOME with
# Debian's skel files, real pass and a scratch GnuPG key and store.
# shellcheck disable=SC2013,SC2016,SC2088

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
		'lendk init sh >> ~/.zshenv' 'lendk init zsh >> ~/.zshrc' 'lendk init systemd >' '~/.zprofile' \
		'It does not protect against' 's2k-count 8388608' 'gpg --passwd' 'default-cache-ttl' 'max-cache-ttl' \
		'gpgconf --reload gpg-agent' '/home/alice/.local/bin/lendk run -- ' 'cron' 'systemd unit' 'MCP' \
		"'!lendk run -- gh auth git-credential'" 'gh auth setup-git' 'npx' 'uv run' \
		'  reserved commands: ' '  lendk-missing (127): ' '## Agent contract' '`lendk: CLASS:` line' \
		'### For humans' '### For AI agents' '<!-- agent-prompt -->' '#### From source' 'make -C lendk uninstall' \
		'`locked`, `timeout` or `canceled`, stop and ask' 'Never run `pass`, `lendk add`, `lendk rm`, or `lendk run` with key names, and never print the environment'; do
		grep -qF -e "$topic" "$README" || { echo "README lacks: $topic" >&2; return 1; }
	done
	assert_eq "$(quickstart | wc -l)" 4
	local features quick
	features=$(grep -n '^## Key features$' "$README" | cut -d: -f1)
	quick=$(grep -n '^## Quick start$' "$README" | cut -d: -f1)
	[[ -n $features && -n $quick ]] && ((features < quick))
	sed -n '/^## Key features$/,/^## /p' "$README" | grep -q '^- '
}

# agent_prompt: the README's fenced prompt for AI agents.
agent_prompt() {
	sed -n '/^<!-- agent-prompt -->$/,/^<!-- agent-prompt -->$/p' "$README" | grep -v -e '^<!--' -e '^```'
}

@test "FR37: the agent prompt covers every step, with only real installer options, classes and lendk verbs" {
	local prompt help opt verb cls point
	prompt=$(agent_prompt)
	help=$("$LENDK" --help)
	[[ -n $prompt ]]
	for point in 'curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash -s -- --yes' \
		'--skill-dir ~/.claude/skills' 'Ask me before rerunning with --install-deps or running' 'anything with sudo' \
		'gpg --quick-generate-key' 'pass init' 'lendk --version' 'bash -lc' '~/.local/share/lendk/shims' \
		'lendk check' 'Only if I agree' 'lendk run ' 'never run pass show' 'never print the environment' \
		'Finish with a short report' 'lendk-install: ok: TEXT'; do
		grep -qF -e "$point" <<<"$prompt" || { echo "agent prompt lacks: $point" >&2; return 1; }
	done
	# The installer URL is the one install.sh names for itself.
	grep -qF "$(sed -n 2p "$ROOT/install.sh" | grep -oE 'curl -fsSL [^ ]+')" <<<"$prompt"
	for opt in $(grep -oE -e '--[a-z][a-z-]+' <<<"$prompt" | sort -u); do
		# Options of install.sh, of lendk, or of the commands install.sh tells the user to run.
		assert_line "$(grep -ohE -e '--[a-z][a-z-]+' "$ROOT/install.sh" <<<"$help" -)" "$opt"
	done
	for verb in $(grep -oE '(^| )lendk [a-z]+' <<<"$prompt" | awk '{ print $2 }' | sort -u); do
		assert_line "$(grep -oE '^  lendk [a-z]+' <<<"$help" | awk '{ print $2 }')" "$verb"
	done
	for cls in $(grep -oE '"lendk: [a-z-]+:' <<<"$prompt" | sed 's/^"lendk: //; s/:$//'); do
		grep -qE "^  $cls \(" <<<"$help" || { echo "agent prompt names unknown class: $cls" >&2; return 1; }
	done
	# The README's installer classes are the ones install.sh can finish with.
	assert_eq "$(sed -n 's/.*with CLASS one of \(.*\)\. `LENDK.*/\1/p' "$README" | tr -d '`,' | sed 's/ or / /' | tr ' ' '\n' | sort)" \
		"$(grep -oE 'finish [a-z-]+' "$ROOT/install.sh" | awk '$2 != "ok" { print $2 }' | sort -u)"
}

@test "FR37: the credential helper snippet leaves only lendk's helper after none, or after gh's two" {
	require git
	local snippet host want
	snippet=$(sed -n '/^### Git credential helper$/,/^###/p' "$README" | sed -n '/^```$/,/^```$/p' | sed '1d;$d')
	want=$'\n!lendk run -- gh auth git-credential'
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
	local sys=$HOME/bin src=$SB/src rel=$SB/rel stub=$SB/stub login_path cmds
	mkdir -p "$sys" "$src" "$rel/latest/download" "$stub"
	ln -s "$FIXTURES/stub-target" "$sys/gh"
	skel_profile >"$HOME/.profile"
	cp "$FIXTURES/bashrc" "$HOME/.bashrc"
	# The release: make dist on a commit of this tree, served from file://.
	cp -R "$ROOT/bin" "$ROOT/skills" "$ROOT/Makefile" "$ROOT/LICENSE" "$ROOT/install.sh" "$src/"
	git -C "$src" init -q
	git -C "$src" add -A
	git -C "$src" -c user.name=test -c user.email=test commit -qm src
	make -s -C "$src" dist >/dev/null
	cp "$src"/dist/* "$rel/latest/download/"
	# The installer looks for a downloader even when file:// URLs need none.
	printf '#!/bin/sh\nexit 7\n' >"$stub/curl"
	chmod +x "$stub/curl"
	login_path=$sys:${BASH%/*}:/usr/bin:/bin
	mapfile -t cmds < <(quickstart)
	assert_eq "${cmds[0]}" 'curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash'
	cmds[0]="cat $(printf %q "$ROOT/install.sh") | bash"
	assert_eq "${cmds[1]}" 'exec bash -l'
	# login CMD...: CMD in $HOME in an environment built from scratch, as a login would start it.
	login() {
		(cd "$HOME" && env -i HOME="$HOME" PATH="$login_path" TERM=dumb STUB_LOG="$STUB_LOG" \
			GNUPGHOME="$GNUPGHOME" PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" "$@")
	}
	login env PATH="$login_path:$stub" LENDK_INSTALL_BASE_URL="file://$rel" bash -c "${cmds[0]}" </dev/null >"$SB/install.out" ||
		{ cat "$SB/install.out" >&2; return 1; }
	[[ $(tail -n 1 "$SB/install.out") == 'lendk-install: ok: '* ]]
	printf '%s\n%s\n' "$SENTINEL" "$SENTINEL" | login bash -lc "${cmds[2]}" >/dev/null
	login bash -lc "${cmds[3]}" </dev/null >/dev/null
	[[ -f $PASSWORD_STORE_DIR/env/GH_TOKEN.gpg ]]
	gpg_prime GH_TOKEN
	login bash -lc gh </dev/null
	local logs=("$SB"/log/target.*)
	assert_eq "${#logs[@]}" 1
	assert_eq "$(tr '\0' '\n' <"${logs[0]}/env" | sed -n 's/^GH_TOKEN=//p')" "$SENTINEL"
}
