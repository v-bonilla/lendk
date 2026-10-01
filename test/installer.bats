#!/usr/bin/env bats
# install.sh against a make dist release served from file://, in a scratch HOME and PREFIX.
# shellcheck disable=SC2016,SC2086 # INST_SH holds a command and its words

setup_file() {
	export BATS_LENDK_REL=$BATS_FILE_TMPDIR/rel BATS_LENDK_SYS=$BATS_FILE_TMPDIR/sys
	local REL=$BATS_LENDK_REL SYS=$BATS_LENDK_SYS
	local src=$BATS_FILE_TMPDIR/src d
	# sys: every command on PATH except the ones a test stubs or hides.
	mkdir -p "$SYS"
	local IFS=:
	for d in $PATH; do
		[[ -d $d ]] && find "$d" -maxdepth 1 \( -type f -o -type l \) -perm -u+x -exec ln -s {} "$SYS/" \; 2>/dev/null
	done
	unset IFS
	(cd "$SYS" && rm -f bash pass gpg gpg2 curl wget apt-get dnf pacman zypper apk brew systemctl sudo)
	command -v git >/dev/null && command -v make >/dev/null || return 0
	# The release: make dist on a commit of this tree.
	mkdir -p "$src"
	cp -R "$BATS_TEST_DIRNAME/../bin" "$BATS_TEST_DIRNAME/../skills" "$BATS_TEST_DIRNAME/../Makefile" "$BATS_TEST_DIRNAME/../LICENSE" "$BATS_TEST_DIRNAME/../install.sh" "$src/"
	git -C "$src" init -q
	git -C "$src" add -A
	git -C "$src" -c user.name=test -c user.email=test commit -qm src
	make -s -C "$src" dist >/dev/null
	mkdir -p "$REL/latest/download" "$REL/download/v1.0.0"
	cp "$src"/dist/* "$REL/latest/download/"
	cp "$src"/dist/* "$REL/download/v1.0.0/"
}

setup() {
	load helpers/common
	sandbox
	REL=$BATS_LENDK_REL SYS=$BATS_LENDK_SYS
	require git
	require make
	[[ -f $REL/latest/download/lendk.tar.gz ]]
	STUB=$SB/stub
	mkdir -p "$STUB"
	ln -s "$BASH" "$STUB/bash"
	stub gpg 'echo "gpg (GnuPG) 2.4.5"'
	stub pass 'exit 0'
	stub curl 'echo "curl: no network in tests" >&2; exit 7'
	VERSION=$(sed -n 's/^LENDK_VERSION=//p' "$LENDK")
	SHIMS=$HOME/.local/share/lendk/shims
	# PM installs pass: HINT is what the installer prints, RUNS what it runs without a terminal.
	if [[ $(uname -s) == Darwin ]]; then
		PM=brew HINT='brew install pass' RUNS='brew install pass' PM_LOG='brew install pass'
	else
		PM=apt-get HINT='sudo apt-get update && sudo apt-get install -y --no-install-recommends pass'
		RUNS=${HINT//sudo /sudo -n }
		PM_LOG=$'sudo -n apt-get update\napt-get update\nsudo -n apt-get install -y --no-install-recommends pass\napt-get install -y --no-install-recommends pass'
	fi
}

# stub NAME BODY: a sh script NAME in the stub directory.
stub() { printf '#!/bin/sh\n%s\n' "$2" >"$STUB/$1" && chmod +x "$STUB/$1"; }

# inst ARG...: install.sh under ${INST_SH:-sh} with a controlled environment and no terminal; sets
# status, output and final, the last line.
inst() {
	status=0
	output=$(env -i HOME="$HOME" PATH="$STUB:$SYS" SHELL="${INST_SHELL:-/bin/bash}" TMPDIR="$TMPDIR" \
		PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" LENDK_INSTALL_BASE_URL="file://$REL" \
		${INST_SH:-sh} "$ROOT/install.sh" "$@" </dev/null 2>&1) || status=$?
	final=${output##*$'\n'}
	[[ $final =~ ^lendk-install:\ (ok|usage|unsupported-os|missing-deps|download|checksum|install|path):\ . ]] ||
		{ printf 'bad final line: %s\n' "$final" >&2; return 1; }
}

# login: PATH, then the lendk and bash a fresh bash login shell resolves.
login() {
	env -i HOME="$HOME" PATH=/usr/bin:/bin "$BASH" -lc 'printf "%s\n" "$PATH"; command -v lendk; command -v bash' </dev/null
}

@test "FR42: installer: a fresh install puts lendk in ~/.local/bin and the shims first on the login PATH" {
	inst
	assert_eq "$status" 0
	assert_eq "$final" "lendk-install: ok: lendk $VERSION installed to $HOME/.local/bin/lendk"
	cmp "$LENDK" "$HOME/.local/bin/lendk"
	[[ -x $HOME/.local/bin/lendk ]]
	assert_line "$output" "updated: $HOME/.profile (lendk-install block)"
	assert_eq "$(grep -c '^# >>> lendk-install >>>$' "$HOME/.profile")" 1
	local out
	mapfile -t out < <(login)
	[[ ${out[0]} == "$SHIMS:"* && ${out[0]} == *":$HOME/.local/bin:"* ]]
	assert_eq "${out[1]}" "$HOME/.local/bin/lendk"
	# The pass store has no .gpg-id, so the installer prints how to create one.
	assert_line "$output" "  pass init 'Your Name'"
}

@test "FR42: installer: a rerun changes nothing, and earlier content of the login file stays" {
	printf 'export EDITOR=vi\n' >"$HOME/.profile"
	inst
	local before
	before=$(<"$HOME/.profile")
	inst
	assert_eq "$status" 0
	assert_line "$output" "unchanged: $HOME/.profile"
	assert_eq "$(<"$HOME/.profile")" "$before"
	assert_eq "$(sed -n 1p "$HOME/.profile")" 'export EDITOR=vi'
}

@test "FR42: installer: zsh users also get ~/.zshenv, and ~/.bash_profile wins over ~/.profile" {
	: >"$HOME/.bash_profile"
	INST_SHELL=/bin/zsh inst
	assert_eq "$status" 0
	grep -qx '# >>> lendk-install >>>' "$HOME/.bash_profile"
	grep -qx '# >>> lendk-install >>>' "$HOME/.zshenv"
	[[ ! -e $HOME/.profile ]]
}

@test "FR42: installer: a first bash older than 4.4 gets a newer one put first in the block" {
	mkdir -p "$SB/good"
	ln -s "$BASH" "$SB/good/bash"
	rm "$STUB/bash"
	stub bash 'exit 1'
	status=0
	output=$(env -i HOME="$HOME" PATH="$STUB:$SB/good:$SYS" SHELL=/bin/bash TMPDIR="$TMPDIR" \
		PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" LENDK_INSTALL_BASE_URL="file://$REL" sh "$ROOT/install.sh" </dev/null 2>&1) || status=$?
	assert_eq "$status" 0
	local out
	mapfile -t out < <(login)
	assert_eq "${out[2]}" "$SB/good/bash"
}

@test "FR40: installer: --version picks the release by tag, and a missing release is a download failure" {
	inst --version 1.0.0
	assert_eq "$status" 0
	inst --version 9.9.9
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: download: cannot download file://$REL/download/v9.9.9/lendk.tar.gz"
}

@test "FR40: installer: a checksum mismatch installs nothing" {
	cp -R "$REL" "$SB/rel"
	printf '%064d  lendk.tar.gz\n' 0 >"$SB/rel/latest/download/SHA256SUMS"
	REL=$SB/rel inst
	assert_eq "$status" 1
	[[ $final == 'lendk-install: checksum: lendk.tar.gz has SHA-256 '*", SHA256SUMS lists '$(printf '%064d' 0)'; nothing was installed" ]]
	[[ ! -e $HOME/.local/bin/lendk && ! -e $HOME/.profile ]]
}

@test "FR41: installer: missing deps print the package manager command and stop; --install-deps runs it" {
	rm "$STUB/pass"
	stub sudo 'echo "sudo $*" >>"$HOME/pm.log"; [ "$1" = -n ] && shift; exec "$@"'
	stub "$PM" "echo \"$PM \$*\" >>\"\$HOME/pm.log\"; printf '#!/bin/sh\nexit 0\n' >'$STUB/pass'; chmod +x '$STUB/pass'"
	inst
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: missing-deps: missing: pass; run: $HINT (or rerun with --install-deps)"
	[[ ! -e $HOME/pm.log && ! -e $HOME/.local/bin/lendk ]]
	inst --install-deps
	assert_eq "$status" 0
	refute_contains "$output" '[y/N]'
	assert_line "$output" "running: $RUNS"
	assert_eq "$(<"$HOME/pm.log")" "$PM_LOG"
	[[ -x $HOME/.local/bin/lendk ]]
}

@test "FR41: a failed package manager run prints the command to run by hand, and sudo -v when sudo is in it" {
	rm "$STUB/pass"
	stub sudo 'echo "sudo: a password is required" >&2; exit 1'
	stub "$PM" 'exit 1'
	inst --install-deps
	assert_eq "$status" 1
	if [[ $PM == brew ]]; then
		assert_eq "$final" "lendk-install: missing-deps: '$RUNS' failed; missing: pass; run it by hand in a terminal: $HINT"
	else
		assert_eq "$final" "lendk-install: missing-deps: '$RUNS' failed; missing: pass; run it by hand in a terminal (sudo -v first if sudo asks for a password): $HINT"
	fi
	[[ ! -e $HOME/.local/bin/lendk ]]
}

@test "FR41: the package command refreshes the index and skips recommended packages for each manager" {
	[[ $(uname -s) == Linux ]] || skip "Linux package managers"
	rm "$STUB/pass"
	local pm want
	for pm in dnf pacman zypper apk; do
		stub "$pm" 'exit 0'
		case $pm in
		dnf) want='sudo dnf install -y --setopt=install_weak_deps=False pass' ;;
		pacman) want='sudo pacman -S --needed --noconfirm pass' ;;
		zypper) want='sudo zypper --non-interactive install --no-recommends password-store' ;;
		apk) want='sudo apk add --no-cache pass' ;;
		esac
		inst
		assert_eq "$final" "lendk-install: missing-deps: missing: pass; run: $want (or rerun with --install-deps)"
		rm "$STUB/$pm"
	done
}

@test "FR41: pacman never runs a partial upgrade; on failure the line says to run pacman -Syu first" {
	[[ $(uname -s) == Linux ]] || skip "Linux package managers"
	rm "$STUB/pass"
	stub sudo 'echo "sudo $*" >>"$HOME/pm.log"; [ "$1" = -n ] && shift; exec "$@"'
	stub pacman 'echo "error: target not found: pass" >&2; exit 1'
	inst --install-deps
	assert_eq "$final" "lendk-install: missing-deps: 'sudo -n pacman -S --needed --noconfirm pass' failed; missing: pass; run it by hand in a terminal (sudo -v first if sudo asks for a password): sudo pacman -S --needed --noconfirm pass; if pacman cannot find a package, run sudo pacman -Syu first, then rerun the installer"
	assert_eq "$(<"$HOME/pm.log")" 'sudo -n pacman -S --needed --noconfirm pass'
}

@test "FR39: installer: piped into bash -s and sh -s, as curl | bash runs it, with a package manager that reads stdin" {
	local shell
	for shell in bash sh; do
		rm -rf "$HOME" && mkdir -p "$HOME"
		rm -f "$STUB/pass"
		stub sudo '[ "$1" = -n ] && shift; exec "$@"'
		stub "$PM" "cat >\"\$HOME/pm.stdin\"; printf '#!/bin/sh\nexit 0\n' >'$STUB/pass'; chmod +x '$STUB/pass'"
		status=0
		output=$(env -i HOME="$HOME" PATH="$STUB:$SYS" SHELL=/bin/bash TMPDIR="$TMPDIR" PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" \
			LENDK_INSTALL_BASE_URL="file://$REL" "$(PATH=$STUB:$SYS command -v "$shell")" -s -- --yes --install-deps <"$ROOT/install.sh" 2>&1) || status=$?
		[[ $status == 0 ]] || { echo "$shell: $output" >&2; return 1; }
		assert_eq "${output##*$'\n'}" "lendk-install: ok: lendk $VERSION installed to $HOME/.local/bin/lendk"
		assert_eq "$(<"$HOME/pm.stdin")" ''
	done
}

@test "FR41: installer: without bash 4.4 it names bash as a missing dependency" {
	[[ ! -x /opt/homebrew/bin/bash && ! -x /usr/local/bin/bash ]] || skip "a newer bash sits in a well-known directory"
	rm "$STUB/bash"
	inst
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: missing-deps: missing: bash>=4.4; no supported package manager found, install them by hand"
}

@test "FR42: installer: --no-modify-path and --prefix leave every login file alone" {
	inst --no-modify-path --prefix "$SB/p"
	assert_eq "$status" 0
	assert_eq "$final" "lendk-install: ok: lendk $VERSION installed to $SB/p/bin/lendk"
	[[ -x $SB/p/bin/lendk ]]
	assert_eq "$(ls -A "$HOME")" ''
}

@test "FR44: installer: --skill-dir copies the agent skill, and --uninstall with it removes the copy" {
	inst --skill-dir "$SB/skills"
	assert_eq "$status" 0
	diff -r "$ROOT/skills/lendk" "$SB/skills/lendk"
	assert_eq "$(sed -n '1,/^name:/p' "$SB/skills/lendk/SKILL.md")" $'---\nname: lendk'
	grep -q '^description: Use when ' "$SB/skills/lendk/SKILL.md"
	inst --uninstall --skill-dir "$SB/skills"
	assert_eq "$status" 0
	[[ ! -e $SB/skills/lendk ]]
}

@test "FR42: installer: with a systemd user session it writes the environment.d file" {
	[[ $(uname -s) == Linux ]] || skip "systemd user sessions are Linux only"
	stub systemctl 'exit 0'
	inst
	assert_eq "$status" 0
	assert_eq "$(sed -n 2p "$HOME/.config/environment.d/99-lendk.conf")" "PATH=$SHIMS:\${PATH}"
	inst --uninstall
	[[ ! -e $HOME/.config/environment.d/99-lendk.conf ]]
}

@test "FR44: installer: --uninstall removes the blocks, shims and lendk, never the map or the store" {
	printf 'export EDITOR=vi\n' >"$HOME/.profile"
	inst
	ln -s "$FIXTURES/stub-target" "$SB/bin/gh"
	env PATH="$SB/bin:$PATH" "$HOME/.local/bin/lendk" add gh GH_TOKEN >/dev/null 2>&1
	[[ -f $SHIMS/gh ]]
	inst --uninstall
	assert_eq "$status" 0
	assert_eq "$final" "lendk-install: ok: lendk uninstalled from $HOME/.local; the map and the pass store are untouched"
	assert_eq "$(<"$HOME/.profile")" 'export EDITOR=vi'
	[[ ! -e $HOME/.local/bin/lendk && ! -e $SHIMS ]]
	assert_eq "$(<"$HOME/.config/lendk/map")" 'gh GH_TOKEN'
	[[ -d $PASSWORD_STORE_DIR ]]
}

@test "FR44: installer: --uninstall keeps a lendk it did not write" {
	mkdir -p "$HOME/.local/bin"
	echo 'not lendk' >"$HOME/.local/bin/lendk"
	inst --uninstall
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: install: $HOME/.local/bin/lendk is not a file the installer wrote, so it stays"
}

@test "FR43: installer: bad options are usage errors" {
	inst --bogus
	assert_eq "$status" 2
	assert_eq "$final" "lendk-install: usage: unknown option '--bogus'; see --help"
	inst --prefix relative
	assert_eq "$status" 2
	inst --version 1.0
	assert_eq "$status" 2
	run sh "$ROOT/install.sh" --help
	assert_eq "$status" 0
	assert_line "$output" '  --uninstall        remove what this installer added, never the map or the pass store'
}

@test "FR44: installer: its markers match the ones bin/lendk and the Makefile use" {
	local m
	m=$(sed -n 2p "$LENDK")
	grep -qxF "lendk_mark='$m'" "$ROOT/install.sh"
	m=$(grep -o "'# lendk shim v1:[^']*'" "$ROOT/install.sh")
	grep -qF "${m//\'/}" "$LENDK"
}

@test "FR39: installer: runs to the end under dash, busybox sh and the system bash" {
	local shell n=0
	for shell in dash 'busybox sh' /bin/bash; do
		command -v "${shell%% *}" >/dev/null || continue
		[[ $shell != busybox* ]] || busybox sh -c : 2>/dev/null || continue
		rm -rf "$HOME" && mkdir -p "$HOME"
		INST_SH=$shell inst
		[[ $status == 0 ]] || { echo "$shell: $output" >&2; return 1; }
		n=$((n + 1))
	done
	((n >= 1))
}

@test "FR39: installer: a truncated download installs nothing, since main runs on the last line" {
	local n
	n=$(wc -l <"$ROOT/install.sh")
	assert_eq "$(tail -n 1 "$ROOT/install.sh")" 'main "$@"'
	head -n "$((n - 1))" "$ROOT/install.sh" >"$SB/cut.sh"
	run env -i HOME="$HOME" PATH="$STUB:$SYS" LENDK_INSTALL_BASE_URL="file://$REL" sh -s -- --yes <"$SB/cut.sh"
	assert_eq "$output" ''
	assert_eq "$(ls -A "$HOME")" ''
}

@test "FR42: installer: a login file without a final newline keeps its last line, across a rerun and an uninstall" {
	printf 'export FOO=bar' >"$HOME/.profile"
	inst
	assert_eq "$status" 0
	assert_eq "$(sed -n 1p "$HOME/.profile")" 'export FOO=bar'
	assert_eq "$(sed -n 2p "$HOME/.profile")" '# >>> lendk-install >>>'
	inst
	assert_line "$output" "unchanged: $HOME/.profile"
	assert_eq "$(grep -c '^# >>> lendk-install >>>$' "$HOME/.profile")" 1
	inst --uninstall
	assert_eq "$status" 0
	assert_eq "$(<"$HOME/.profile")" 'export FOO=bar'
}

@test "FR42: installer: a quote in the prefix stays quoted in the login block" {
	local p="$SB/o'brien"
	inst --prefix "$p"
	assert_eq "$status" 0
	local out
	mapfile -t out < <(login)
	[[ ${out[0]} == *":$p/bin:"* ]]
	assert_eq "${out[1]}" "$p/bin/lendk"
}

@test "FR43: installer: the final line comes on a bad HOME and on a signal; the temporary directory goes" {
	status=0
	output=$(env -i PATH="$STUB:$SYS" sh "$ROOT/install.sh" </dev/null 2>&1) || status=$?
	assert_eq "$status" 2
	assert_eq "$output" 'lendk-install: usage: HOME is not an absolute path; set HOME and rerun'
	rm "$STUB/pass"
	stub sudo 'shift; exec "$@"'
	# The package manager stands for any step the user interrupts.
	# It signals the nearest ancestor running install.sh, since sh -c may exec it or fork it.
	stub "$PM" 'p=$PPID
for i in 1 2 3; do
	case $(ps -o args= -p "$p") in *install.sh*) kill -TERM "$p"; sleep 1; exit 0 ;; esac
	p=$(ps -o ppid= -p "$p" | tr -d " ")
done
exit 1'
	inst --install-deps
	assert_eq "$status" 1
	assert_eq "$final" 'lendk-install: install: interrupted by a signal; rerun the installer'
	assert_eq "$(ls -A "$TMPDIR")" ''
	run sh "$ROOT/install.sh" --help
	assert_eq "$status" 0
	[[ ${output##*$'\n'} != lendk-install:* ]]
}

@test "FR40: installer: a base URL other than https:// or file:/// is refused" {
	status=0
	output=$(env -i HOME="$HOME" PATH="$STUB:$SYS" LENDK_INSTALL_BASE_URL=http://example.org sh "$ROOT/install.sh" </dev/null 2>&1) || status=$?
	assert_eq "$status" 2
	assert_eq "$output" "lendk-install: usage: LENDK_INSTALL_BASE_URL must start with https:// or file:///, not 'http://example.org'"
	refute_contains "$(sed -n '/^fetch()/,/^}/p' "$ROOT/install.sh")" 'wget -q -O'$'\n'
	grep -q -- "--proto '=https'" "$ROOT/install.sh"
}

@test "FR41: installer: an uninitialized store gets steps a human runs in their own terminal" {
	inst
	assert_line "$output" 'these steps in their own terminal:'
	assert_line "$output" "  gpg --quick-generate-key 'Your Name' default default never"
	mkdir -p "$PASSWORD_STORE_DIR" && echo ID >"$PASSWORD_STORE_DIR/.gpg-id"
	inst
	refute_contains "$output" 'quick-generate-key'
}

# bats test_tags=docker
@test "FR39: installer: runs under bash 3.2 and stops on missing deps" {
	require docker
	status=0
	output=$(docker run --rm --pull never -u "$(id -u):$(id -g)" -e HOME=/tmp -e LENDK_INSTALL_BASE_URL=file:///rel \
		-v "$ROOT/install.sh:/install.sh:ro" -v "$REL:/rel:ro" bash:3.2.57 bash /install.sh --yes 2>&1 </dev/null) || status=$?
	assert_eq "$status" 1
	assert_eq "${output##*$'\n'}" 'lendk-install: missing-deps: missing: bash>=4.4 gnupg>=2.4 pass; run: sudo apk add --no-cache bash gnupg pass (or rerun with --install-deps)'
}

# bats test_tags=docker
@test "FR39: installer: installs end to end under dash on Ubuntu and busybox sh on Alpine" {
	require docker
	local image shell
	mkdir -p "$SB/cstub"
	cp "$STUB/gpg" "$STUB/pass" "$STUB/curl" "$SB/cstub/"
	for image in lendk-test:ubuntu:dash lendk-test:bash44:sh; do
		shell=${image##*:}
		image=${image%:*}
		status=0
		output=$(docker run --rm --pull never -u "$(id -u):$(id -g)" -e HOME=/tmp/h -e LENDK_INSTALL_BASE_URL=file:///rel \
			-e PATH=/stub:/usr/local/bin:/usr/bin:/bin -v "$ROOT/install.sh:/install.sh:ro" -v "$REL:/rel:ro" -v "$SB/cstub:/stub:ro" \
			"$image" sh -c "mkdir -p /tmp/h && $shell /install.sh --yes && env -i HOME=/tmp/h PATH=/usr/local/bin:/usr/bin:/bin bash -lc 'command -v lendk'" 2>&1 </dev/null) || status=$?
		[[ $status == 0 ]] || { echo "$image: $output" >&2; return 1; }
		assert_line "$output" "lendk-install: ok: lendk $VERSION installed to /tmp/h/.local/bin/lendk"
		assert_eq "${output##*$'\n'}" /tmp/h/.local/bin/lendk
	done
}
