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

# bare CMD: CMD without a trailing comment.
bare() {
	local cmd=${1%%[[:space:]]#*}
	printf '%s\n' "${cmd%"${cmd##*[![:space:]]}"}"
}

# headings: the README's heading lines, those inside code fences left out.
headings() { awk '/^```/ { fence = !fence } !fence && /^#+ /' "$README"; }

# anchor: GitHub's anchor for each heading line on stdin: lowercase, punctuation dropped, spaces to hyphens.
anchor() { sed 's/^#* //' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 _-]//g; s/ /-/g'; }

# section HEADING: the README from the line HEADING to the next heading of level two or deeper.
section() { sed -n "/^$1\$/,/^##/p" "$README"; }

@test "FR37: the README covers every topic" {
	local topic
	for topic in '<!-- quickstart -->' 'Install only from this repository' \
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
	# The outline: contents, key features, the quick start for humans, the two examples, installation, uninstall.
	local heading n last=0
	for heading in '## Contents' '## Key features' '## Quick start for humans' '## Examples' '### gh with a GitHub token' \
		'### A group of keys for Claude Code or Codex' '## Installation' '## Uninstall'; do
		n=$(headings | grep -nxF -e "$heading" | cut -d: -f1)
		if ! [[ $n =~ ^[0-9]+$ ]] || ((n <= last)); then
			echo "README heading missing, repeated or out of order: $heading" >&2
			return 1
		fi
		last=$n
	done
	section '## Key features' | grep -q '^- '
	# Each example holds its commands, and the group example shows the map lines add writes.
	for topic in 'pass insert env/GH_TOKEN' 'lendk add gh GH_TOKEN' 'echo "${GH_TOKEN:-not set}"'; do
		section '### gh with a GitHub token' | grep -qF -e "$topic" || { echo "gh example lacks: $topic" >&2; return 1; }
	done
	for topic in 'pass insert env/EXA_API_KEY' 'pass insert env/BRAVE_API_KEY' 'lendk add @search EXA_API_KEY BRAVE_API_KEY' \
		'lendk add --force claude @search' 'lendk add --force codex @search' 'lendk run EXA_API_KEY -- ' \
		'(#cron-systemd-units-mcp-servers)'; do
		section '### A group of keys for Claude Code or Codex' | grep -qF -e "$topic" ||
			{ echo "group example lacks: $topic" >&2; return 1; }
	done
	for topic in '@search EXA_API_KEY BRAVE_API_KEY' 'claude @search' 'codex @search'; do
		section '### A group of keys for Claude Code or Codex' | grep -qxF -e "$topic" ||
			{ echo "group example lacks the map line: $topic" >&2; return 1; }
	done
}

@test "FR37: the install command for humans is the quick start's first command" {
	local cmd
	cmd=$(section '### For humans' | awk '/^```/ { if (fence) exit; fence = 1; next } fence')
	assert_eq "$cmd" "$(quickstart | head -n 1)"
}

@test "FR37: the Contents list links every section, and every in-page link names a heading" {
	local anchors listed link
	anchors=$(headings | anchor)
	assert_eq "$(sort <<<"$anchors" | uniq -d)" ''
	for link in $(grep -oE '\]\(#[^)]*\)' "$README" | sed 's/^](#//; s/)$//' | sort -u); do
		assert_line "$anchors" "$link"
	done
	listed=$(section '## Contents' | grep -oE '^ *- \[[^]]+\]\(#[^)]*\)$' | sed 's/.*](#//; s/)$//')
	for link in $(headings | grep '^## ' | anchor); do
		[[ $link == contents ]] || assert_line "$listed" "$link"
	done
}

@test "FR37: uninstall has a section of its own, and elsewhere only the option list and links name it" {
	local own point line rest n=0
	own=$(section '## Uninstall')
	for point in 'install.sh | bash -s -- --uninstall' 'never removes the map or the pass store' '--skill-dir DIR' \
		'# >>> lendk >>>' 'environment.d file' 'make -C lendk uninstall'; do
		grep -qF -e "$point" <<<"$own" || { echo "the Uninstall section lacks: $point" >&2; return 1; }
	done
	while IFS= read -r line; do
		# A line that only links to the section passes; any other must be the installer's option row.
		rest=${line//'[Uninstall](#uninstall)'/}
		if [[ ${rest,,} == *uninstall* ]]; then
			assert_line "$(sh "$ROOT/install.sh" --help)" "  $line"
			n=$((n + 1))
		fi
	done < <(awk '/^## / { own = ($0 == "## Uninstall") } !own' "$README" | grep -i -e uninstall)
	assert_eq "$n" 1
}

@test "FR37: the Upgrade section sits between Installation and Uninstall and covers the verb, its trust and the installer's part" {
	local heading n last=0 own topic
	for heading in '## Installation' '## Upgrade' '## Uninstall'; do
		n=$(headings | grep -nxF -e "$heading" | cut -d: -f1)
		if ! [[ $n =~ ^[0-9]+$ ]] || ((n <= last)); then
			echo "README heading missing, repeated or out of order: $heading" >&2
			return 1
		fi
		last=$n
	done
	own=$(section '## Upgrade')
	assert_line "$own" 'lendk upgrade'
	assert_line "$own" 'From a checkout: `git pull`, then `make install`.'
	for topic in 'the installed `lendk`' 'It leaves everything else alone: the map, the pass store, your login files, the environment.d file and a skill copy.' \
		'`--skill-dir DIR`' '`--version X.Y.Z`' 'rerun the installer' 'a symlink' 'a directory you cannot write' \
		'tar, gzip, `sha256sum` or `shasum`, and curl or wget' '`LENDK_TIMEOUT`' '`LENDK_INSTALL_BASE_URL`' \
		"trusts this project's GitHub releases over HTTPS" 'whoever serves the URL' '(#security-model)'; do
		grep -qF -e "$topic" <<<"$own" || { echo "the Upgrade section lacks: $topic" >&2; return 1; }
	done
	grep -qF -e 'The checksum comes from the same release' <<<"$(section '### Security model')"
	assert_line "$(section '## Agent contract')" '- Run `lendk upgrade` only when the user asks, and never set `LENDK_INSTALL_BASE_URL`.'
}

@test "FR37: the README's statements about network use name lendk upgrade alone" {
	local line
	grep -qF -e 'It uses the network only when you run `lendk upgrade`.' <<<"$(section '## Key features')"
	grep -qF -e 'lendk uses the network only in `lendk upgrade`, and only when you run it.' <<<"$(section '## How it works')"
	# Every other line that speaks of the network sits in the Upgrade section or names the installer.
	while IFS= read -r line; do
		[[ $line == *'`lendk upgrade`'* ]] || { echo "README line on network use without lendk upgrade: $line" >&2; return 1; }
	done < <(awk '/^## / { own = ($0 == "## Upgrade") } !own' "$README" | grep -i -e network)
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
		'Finish with a short report' 'lendk-install: ok: TEXT' 'even when the run fails' \
		'~/.local/bin/lendk run DEMO_TOKEN' '~/.local/bin/lendk unlock DEMO_TOKEN'; do
		grep -qF -e "$point" <<<"$prompt" || { echo "agent prompt lacks: $point" >&2; return 1; }
	done
	# The agent's shell predates the PATH change, so it runs lendk by path or in a login shell.
	if grep -E '(^|[ "])lendk (run|unlock|check|--version)' <<<"$prompt"; then return 1; fi
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
	# A command may end in a comment, as the README's second one does; commands 3 and 4 run with theirs.
	assert_eq "$(bare "${cmds[0]}")" \
		'curl -fsSL https://raw.githubusercontent.com/v-bonilla/lendk/main/install.sh | bash -s -- --skill-dir ~/.claude/skills'
	cmds[0]="cat $(printf %q "$ROOT/install.sh") | ${cmds[0]#*'| '}"
	assert_eq "$(bare "${cmds[1]}")" 'exec bash -l'
	# login CMD...: CMD in $HOME in an environment built from scratch, as a login would start it.
	login() {
		(cd "$HOME" && env -i HOME="$HOME" PATH="$login_path" TERM=dumb STUB_LOG="$STUB_LOG" \
			GNUPGHOME="$GNUPGHOME" PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" "$@")
	}
	login env PATH="$login_path:$stub" LENDK_INSTALL_BASE_URL="file://$rel" bash -c "${cmds[0]}" </dev/null >"$SB/install.out" ||
		{ cat "$SB/install.out" >&2; return 1; }
	[[ $(tail -n 1 "$SB/install.out") == 'lendk-install: ok: '* ]]
	grep -qx 'name: lendk' "$HOME/.claude/skills/lendk/SKILL.md"
	printf '%s\n%s\n' "$SENTINEL" "$SENTINEL" | login bash -lc "${cmds[2]}" >/dev/null
	login bash -lc "${cmds[3]}" </dev/null >/dev/null
	[[ -f $PASSWORD_STORE_DIR/env/GH_TOKEN.gpg ]]
	gpg_prime GH_TOKEN
	login bash -lc gh </dev/null
	local logs=("$SB"/log/target.*)
	assert_eq "${#logs[@]}" 1
	assert_eq "$(tr '\0' '\n' <"${logs[0]}/env" | sed -n 's/^GH_TOKEN=//p')" "$SENTINEL"
}
