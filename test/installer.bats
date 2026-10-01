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
	PM=apt-get PM_RUN="sudo -n apt-get install -y" PM_LOG=$'sudo -n apt-get install -y pass\napt-get install -y pass'
	if [[ $(uname -s) == Darwin ]]; then PM=brew PM_RUN="brew install" PM_LOG="brew install pass"; fi
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

@test "installer: a fresh install puts lendk in ~/.local/bin and the shims first on the login PATH" {
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

@test "installer: a rerun changes nothing, and earlier content of the login file stays" {
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

@test "installer: zsh users also get ~/.zshenv, and ~/.bash_profile wins over ~/.profile" {
	: >"$HOME/.bash_profile"
	INST_SHELL=/bin/zsh inst
	assert_eq "$status" 0
	grep -qx '# >>> lendk-install >>>' "$HOME/.bash_profile"
	grep -qx '# >>> lendk-install >>>' "$HOME/.zshenv"
	[[ ! -e $HOME/.profile ]]
}

@test "installer: a first bash older than 4.4 gets a newer one put first in the block" {
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

@test "installer: --version picks the release by tag, and a missing release is a download failure" {
	inst --version 1.0.0
	assert_eq "$status" 0
	inst --version 9.9.9
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: download: cannot download file://$REL/download/v9.9.9/lendk.tar.gz"
}

@test "installer: a checksum mismatch installs nothing" {
	cp -R "$REL" "$SB/rel"
	printf '%064d  lendk.tar.gz\n' 0 >"$SB/rel/latest/download/SHA256SUMS"
	REL=$SB/rel inst
	assert_eq "$status" 1
	[[ $final == 'lendk-install: checksum: lendk.tar.gz has SHA-256 '*", SHA256SUMS lists '$(printf '%064d' 0)'; nothing was installed" ]]
	[[ ! -e $HOME/.local/bin/lendk && ! -e $HOME/.profile ]]
}

@test "installer: missing deps print the package manager command and stop; --install-deps runs it" {
	rm "$STUB/pass"
	stub sudo 'echo "sudo $*" >>"$HOME/pm.log"; [ "$1" = -n ] && shift; exec "$@"'
	stub "$PM" "echo \"$PM \$*\" >>\"\$HOME/pm.log\"; printf '#!/bin/sh\nexit 0\n' >'$STUB/pass'; chmod +x '$STUB/pass'"
	inst
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: missing-deps: missing: pass; run: $PM_RUN pass (or rerun with --install-deps)"
	[[ ! -e $HOME/pm.log && ! -e $HOME/.local/bin/lendk ]]
	inst --install-deps
	assert_eq "$status" 0
	refute_contains "$output" '[y/N]'
	assert_line "$output" "running: $PM_RUN pass"
	assert_eq "$(<"$HOME/pm.log")" "$PM_LOG"
	[[ -x $HOME/.local/bin/lendk ]]
}

@test "installer: piped into bash -s and sh -s, as curl | bash runs it, with a package manager that reads stdin" {
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

@test "installer: without bash 4.4 it names bash as a missing dependency" {
	[[ ! -x /opt/homebrew/bin/bash && ! -x /usr/local/bin/bash ]] || skip "a newer bash sits in a well-known directory"
	rm "$STUB/bash"
	inst
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: missing-deps: missing: bash>=4.4; no supported package manager found, install them by hand"
}

@test "installer: --no-modify-path and --prefix leave every login file alone" {
	inst --no-modify-path --prefix "$SB/p"
	assert_eq "$status" 0
	assert_eq "$final" "lendk-install: ok: lendk $VERSION installed to $SB/p/bin/lendk"
	[[ -x $SB/p/bin/lendk ]]
	assert_eq "$(ls -A "$HOME")" ''
}

@test "installer: --skill-dir copies the agent skill, and --uninstall with it removes the copy" {
	inst --skill-dir "$SB/skills"
	assert_eq "$status" 0
	diff -r "$ROOT/skills/lendk" "$SB/skills/lendk"
	assert_eq "$(sed -n '1,/^name:/p' "$SB/skills/lendk/SKILL.md")" $'---\nname: lendk'
	grep -q '^description: Use when ' "$SB/skills/lendk/SKILL.md"
	inst --uninstall --skill-dir "$SB/skills"
	assert_eq "$status" 0
	[[ ! -e $SB/skills/lendk ]]
}

@test "installer: with a systemd user session it writes the environment.d file" {
	[[ $(uname -s) == Linux ]] || skip "systemd user sessions are Linux only"
	stub systemctl 'exit 0'
	inst
	assert_eq "$status" 0
	assert_eq "$(sed -n 2p "$HOME/.config/environment.d/99-lendk.conf")" "PATH=$SHIMS:\${PATH}"
	inst --uninstall
	[[ ! -e $HOME/.config/environment.d/99-lendk.conf ]]
}

@test "installer: --uninstall removes the blocks, shims and lendk, never the map or the store" {
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

@test "installer: --uninstall keeps a lendk it did not write" {
	mkdir -p "$HOME/.local/bin"
	echo 'not lendk' >"$HOME/.local/bin/lendk"
	inst --uninstall
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: install: $HOME/.local/bin/lendk is not a file the installer wrote, so it stays"
}

@test "installer: bad options are usage errors" {
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

@test "installer: its markers match the ones bin/lendk and the Makefile use" {
	local m
	m=$(sed -n 2p "$LENDK")
	grep -qxF "lendk_mark='$m'" "$ROOT/install.sh"
	m=$(grep -o "'# lendk shim v1:[^']*'" "$ROOT/install.sh")
	grep -qF "${m//\'/}" "$LENDK"
}

@test "installer: runs to the end under dash, busybox sh and the system bash" {
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

# bats test_tags=docker
@test "installer: runs under bash 3.2 and stops on missing deps" {
	require docker
	status=0
	output=$(docker run --rm --pull never -u "$(id -u):$(id -g)" -e HOME=/tmp -e LENDK_INSTALL_BASE_URL=file:///rel \
		-v "$ROOT/install.sh:/install.sh:ro" -v "$REL:/rel:ro" bash:3.2.57 bash /install.sh --yes 2>&1 </dev/null) || status=$?
	assert_eq "$status" 1
	assert_eq "${output##*$'\n'}" 'lendk-install: missing-deps: missing: bash>=4.4 gnupg>=2.4 pass; run: sudo -n apk add bash gnupg pass (or rerun with --install-deps)'
}

# bats test_tags=docker
@test "installer: installs end to end under dash on Ubuntu and busybox sh on Alpine" {
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
