#!/usr/bin/env bats
# install.sh against the frozen 1.x lendk's release and the binary's, served from file://.
# shellcheck disable=SC2016,SC2086 # INST_SH holds a command and its words

setup_file() {
	export BATS_LENDK_REL=$BATS_FILE_TMPDIR/rel BATS_LENDK_SYS=$BATS_FILE_TMPDIR/sys
	local REL=$BATS_LENDK_REL SYS=$BATS_LENDK_SYS
	local d
	load helpers/common
	# sys: every command on PATH except the ones a test stubs or hides.
	mkdir -p "$SYS"
	local IFS=:
	for d in $PATH; do
		[[ -d $d ]] && find "$d" -maxdepth 1 \( -type f -o -type l \) -perm -u+x -exec ln -s {} "$SYS/" \; 2>/dev/null
	done
	unset IFS
	(cd "$SYS" && rm -f bash pass gpg gpg2 curl wget apt-get dnf pacman zypper apk brew systemctl sudo)
	release_1x "$REL"
	# The binary's release: the lendk under test in this platform's archive.
	export BATS_LENDK_BREL=$BATS_FILE_TMPDIR/brel
	release "$BATS_LENDK_BREL" "$RUNNING"
	mkdir -p "$BATS_LENDK_BREL/download/v$RUNNING"
	cp "$BATS_LENDK_BREL"/latest/download/* "$BATS_LENDK_BREL/download/v$RUNNING/"
}

setup() {
	load helpers/common
	sandbox
	REL=$BATS_LENDK_REL SYS=$BATS_LENDK_SYS BREL=$BATS_LENDK_BREL
	[[ -f $REL/latest/download/lendk.tar.gz ]]
	STUB=$SB/stub
	mkdir -p "$STUB"
	ln -s "$BASH" "$STUB/bash"
	stub gpg 'echo "gpg (GnuPG) 2.4.5"'
	stub pass 'exit 0'
	stub curl 'echo "curl: no network in tests" >&2; exit 7'
	VERSION=$(sed -n 's/^LENDK_VERSION=//p' "$FIXTURES/lendk-1.x")
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

# binst ARG...: inst against the binary's release.
binst() { REL=$BREL inst "$@"; }

# platform S M [ARM64]: uname prints S for -s and M for -m, and sysctl ARM64 for hw.optional.arm64.
platform() {
	stub uname "case \$1 in -s) echo $1 ;; -m) echo $2 ;; *) exit 1 ;; esac"
	stub sysctl "[ \"\$*\" = '-n hw.optional.arm64' ] && echo ${3:-0}"
}

# login: PATH, then the lendk and bash a fresh bash login shell resolves.
login() {
	env -i HOME="$HOME" PATH=/usr/bin:/bin "$BASH" -lc 'printf "%s\n" "$PATH"; command -v lendk; command -v bash' </dev/null
}

@test "installer: a fresh install puts lendk in ~/.local/bin and the shims first on the login PATH" {
	inst
	assert_eq "$status" 0
	assert_eq "$final" "lendk-install: ok: lendk $VERSION installed to $HOME/.local/bin/lendk"
	cmp "$FIXTURES/lendk-1.x" "$HOME/.local/bin/lendk"
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

@test "installer: --version picks the release by tag, and a missing release is a download failure of its SHA256SUMS" {
	inst --version "$VERSION"
	assert_eq "$status" 0
	inst --version 9.9.9
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: download: cannot download file://$REL/download/v9.9.9/SHA256SUMS"
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
	assert_eq "$final" "lendk-install: missing-deps: missing: pass; run: $HINT (or rerun with --install-deps)"
	[[ ! -e $HOME/pm.log && ! -e $HOME/.local/bin/lendk ]]
	inst --install-deps
	assert_eq "$status" 0
	refute_contains "$output" '[y/N]'
	assert_line "$output" "running: $RUNS"
	assert_eq "$(<"$HOME/pm.log")" "$PM_LOG"
	[[ -x $HOME/.local/bin/lendk ]]
}

@test "a failed package manager run prints the command to run by hand, and sudo -v when sudo is in it" {
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

@test "the package command refreshes the index and skips recommended packages for each manager" {
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

@test "pacman never runs a partial upgrade; on failure the line says to run pacman -Syu first" {
	[[ $(uname -s) == Linux ]] || skip "Linux package managers"
	rm "$STUB/pass"
	stub sudo 'echo "sudo $*" >>"$HOME/pm.log"; [ "$1" = -n ] && shift; exec "$@"'
	stub pacman 'echo "error: target not found: pass" >&2; exit 1'
	inst --install-deps
	assert_eq "$final" "lendk-install: missing-deps: 'sudo -n pacman -S --needed --noconfirm pass' failed; missing: pass; run it by hand in a terminal (sudo -v first if sudo asks for a password): sudo pacman -S --needed --noconfirm pass; if pacman cannot find a package, run sudo pacman -Syu first, then rerun the installer"
	assert_eq "$(<"$HOME/pm.log")" 'sudo -n pacman -S --needed --noconfirm pass'
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

@test "installer: without curl or wget, or without tar, it names the missing tool" {
	rm "$STUB/curl"
	inst
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: missing-deps: missing: curl; no supported package manager found, install them by hand"
	stub curl 'exit 7'
	mkdir "$SB/sys"
	find "$SYS" -mindepth 1 -maxdepth 1 ! -name tar -exec ln -s {} "$SB/sys/" \;
	SYS=$SB/sys inst
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: missing-deps: missing: tar; no supported package manager found, install them by hand"
	[[ ! -e $HOME/.local/bin/lendk ]]
}

@test "installer: zsh users on macOS also get the block in ~/.zprofile" {
	stub uname 'echo Darwin'
	INST_SHELL=/bin/zsh inst
	assert_eq "$status" 0
	grep -qx '# >>> lendk-install >>>' "$HOME/.zprofile"
	grep -qx '# >>> lendk-install >>>' "$HOME/.zshenv"
}

@test "installer: a rerun with another --prefix replaces the login block" {
	local one
	inst --prefix "$SB/one"
	assert_eq "$status" 0
	one=$(<"$HOME/.profile")
	assert_line "$one" "case :\$PATH: in *:'$SB/one/bin':*) ;; *) PATH='$SB/one/bin':\$PATH ;; esac"
	inst --prefix "$SB/two"
	assert_eq "$status" 0
	assert_line "$output" "updated: $HOME/.profile (lendk-install block)"
	assert_eq "$(grep -c '^# >>> lendk-install >>>$' "$HOME/.profile")" 1
	assert_eq "$(<"$HOME/.profile")" "${one//"$SB/one/bin"/"$SB/two/bin"}"
}

@test "installer: on macOS without Homebrew it points to brew.sh and installs nothing" {
	stub uname 'echo Darwin'
	rm "$STUB/pass"
	inst --install-deps
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: missing-deps: missing: pass; Homebrew is required on macOS: install it from https://brew.sh, then run: brew install pass, and rerun this installer"
	[[ ! -e $HOME/.local/bin/lendk ]]
	[[ $output != *running:* ]]
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

@test "installer: the markers match across the frozen 1.x lendk, the Rust source, install.sh and the Makefile" {
	local m
	# 1.x's second line.
	m=$(sed -n 2p "$FIXTURES/lendk-1.x")
	grep -qxF "lendk_mark='$m'" "$ROOT/install.sh"
	grep -qxF "LENDK_MARKER := \\$m" "$ROOT/Makefile"
	# The binary's marker.
	m=$(sed -n 's/^pub static MARKER: \[u8; [0-9]*\] = \*b"\(.*\)";$/\1/p' "$ROOT/src/upgrade.rs")
	[[ -n $m ]]
	grep -qxF "BIN_MARKER := $m" "$ROOT/Makefile"
	grep -qxF "bin_mark='$m'" "$ROOT/install.sh"
	# The shim's second line.
	m=$(grep -o "'# lendk shim v1:[^']*'" "$ROOT/install.sh")
	m=${m//\'/}
	grep -qxF "MARKER := \\$m" "$ROOT/Makefile"
	assert_eq "$(sed -n 2p "$ROOT/test/frozen/shim")" "$m"
}

@test "installer: runs to the end under dash, busybox sh and the system bash, for 1.x and the binary" {
	local shell n=0
	for shell in dash 'busybox sh' /bin/bash; do
		command -v "${shell%% *}" >/dev/null || continue
		[[ $shell != busybox* ]] || busybox sh -c : 2>/dev/null || continue
		rm -rf "$HOME" && mkdir -p "$HOME"
		INST_SH=$shell inst
		[[ $status == 0 ]] || { echo "$shell: $output" >&2; return 1; }
		INST_SH=$shell binst
		[[ $status == 0 ]] || { echo "$shell: $output" >&2; return 1; }
		n=$((n + 1))
	done
	((n >= 1))
}

@test "installer: a truncated download installs nothing, since main runs on the last line" {
	local n
	n=$(wc -l <"$ROOT/install.sh")
	assert_eq "$(tail -n 1 "$ROOT/install.sh")" 'main "$@"'
	head -n "$((n - 1))" "$ROOT/install.sh" >"$SB/cut.sh"
	run env -i HOME="$HOME" PATH="$STUB:$SYS" LENDK_INSTALL_BASE_URL="file://$REL" sh -s -- --yes <"$SB/cut.sh"
	assert_eq "$output" ''
	assert_eq "$(ls -A "$HOME")" ''
}

@test "installer: a login file without a final newline keeps its last line, across a rerun and an uninstall" {
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

@test "installer: a quote in the prefix stays quoted in the login block" {
	local p="$SB/o'brien"
	inst --prefix "$p"
	assert_eq "$status" 0
	local out
	mapfile -t out < <(login)
	[[ ${out[0]} == *":$p/bin:"* ]]
	assert_eq "${out[1]}" "$p/bin/lendk"
}

@test "installer: the final line comes on a bad HOME and on a signal; the temporary directory goes" {
	status=0
	output=$(env -i PATH="$STUB:$SYS" sh "$ROOT/install.sh" </dev/null 2>&1) || status=$?
	assert_eq "$status" 2
	assert_eq "$output" 'lendk-install: usage: HOME is not an absolute path; set HOME and rerun'
	rm "$STUB/pass"
	stub sudo 'shift; exec "$@"'
	# The package manager stands for any step the user interrupts.
	# It signals the nearest ancestor running install.sh, since sh -c may exec it or fork it. It reads
	# /proc where there is one, since busybox ps has no -p.
	stub "$PM" 'p=$PPID
for i in 1 2 3; do
	if [ -r /proc/$p/status ]; then
		args=$(tr "\0" " " </proc/$p/cmdline) ppid=$(sed -n "s/^PPid:[[:space:]]*//p" /proc/$p/status)
	else
		args=$(ps -o args= -p "$p") ppid=$(ps -o ppid= -p "$p" | tr -d " ")
	fi
	case $args in *install.sh*) kill -TERM "$p"; sleep 1; exit 0 ;; esac
	p=$ppid
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

@test "installer: a base URL other than https:// or file:/// is refused" {
	status=0
	output=$(env -i HOME="$HOME" PATH="$STUB:$SYS" LENDK_INSTALL_BASE_URL=http://example.org sh "$ROOT/install.sh" </dev/null 2>&1) || status=$?
	assert_eq "$status" 2
	assert_eq "$output" "lendk-install: usage: LENDK_INSTALL_BASE_URL must start with https:// or file:///, not 'http://example.org'"
	refute_contains "$(sed -n '/^fetch()/,/^}/p' "$ROOT/install.sh")" 'wget -q -O'$'\n'
	grep -q -- "--proto '=https'" "$ROOT/install.sh"
}

@test "installer: an uninitialized store gets steps a human runs in their own terminal" {
	inst
	assert_line "$output" 'these steps in their own terminal:'
	assert_line "$output" "  gpg --quick-generate-key 'Your Name' default default never"
	mkdir -p "$PASSWORD_STORE_DIR" && echo ID >"$PASSWORD_STORE_DIR/.gpg-id"
	inst
	refute_contains "$output" 'quick-generate-key'
}

@test "installer: a binary release installs this platform's binary, needing no bash, GnuPG or pass" {
	rm "$STUB/bash" "$STUB/gpg" "$STUB/pass"
	platform Linux "$(uname -m)"
	binst
	assert_eq "$status" 0
	assert_eq "$final" "lendk-install: ok: lendk $RUNNING installed to $HOME/.local/bin/lendk"
	cmp "$UNDER_TEST" "$HOME/.local/bin/lendk"
	[[ $(ls -l "$HOME/.local/bin/lendk") == -rwxr-xr-x* ]]
	assert_eq "$(ls -A "$HOME/.local/bin")" lendk
	assert_eq "$(sed -n 2p "$HOME/.profile")" "case :\$PATH: in *:'$HOME/.local/bin':*) ;; *) PATH='$HOME/.local/bin':\$PATH ;; esac"
	refute_contains "$(<"$HOME/.profile")" bash
	local out
	mapfile -t out < <(login)
	[[ ${out[0]} == "$SHIMS:"* ]]
	assert_eq "${out[1]}" "$HOME/.local/bin/lendk"
	binst --version "$RUNNING"
	assert_eq "$status" 0
	assert_line "$output" "unchanged: $HOME/.profile"
}

# standin_release DIR VERSION [ASSET]: a stand-in printing lendk VERSION, packed as ASSET.
standin_release() {
	ASSET=${3:-$ASSET} release "$1" "$2"
}

# sed_file SCRIPT FILE: FILE edited by sed in place, keeping its mode.
sed_file() { sed "$1" "$2" >"$SB/sed.out" && cat "$SB/sed.out" >"$2"; }

# nothing_installed: no lendk, no staged file, no login file.
nothing_installed() {
	[[ ! -e $HOME/.local/bin/lendk && ! -e $HOME/.profile ]]
	assert_eq "$(ls -A "$HOME/.local/bin" 2>/dev/null)" ''
}

@test "installer: SHA256SUMS picks the platform's archive over lendk.tar.gz, and its lines may mark the file binary" {
	local r=$SB/r
	cp -R "$BREL" "$r"
	cp "$REL/latest/download/lendk.tar.gz" "$r/latest/download/"
	{ sed 's/  / */' "$BREL/latest/download/SHA256SUMS"; cat "$REL/latest/download/SHA256SUMS"; } >"$r/latest/download/SHA256SUMS"
	REL=$r inst
	assert_eq "$status" 0
	cmp "$UNDER_TEST" "$HOME/.local/bin/lendk"
	assert_line "$output" "downloading file://$r/latest/download/$ASSET"
	sed_file "/$ASSET/d" "$r/latest/download/SHA256SUMS"
	REL=$r inst
	assert_eq "$status" 0
	cmp "$FIXTURES/lendk-1.x" "$HOME/.local/bin/lendk"
}

@test "installer: a release with neither archive fails naming the release and the platform" {
	local r=$SB/r
	cp -R "$BREL" "$r"
	sed_file s/lendk-/lendk-x/ "$r/latest/download/SHA256SUMS"
	sed_file s/lendk-/lendk-x/ "$r/download/v$RUNNING/SHA256SUMS"
	REL=$r inst
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: download: the latest release has no archive for $PLATFORM; nothing was installed"
	REL=$r inst --version "$RUNNING"
	assert_eq "$final" "lendk-install: download: the release $RUNNING has no archive for $PLATFORM; nothing was installed"
	nothing_installed
}

@test "installer: an arm64 Mac in a Rosetta shell gets the arm64 archive, and an Intel Mac the x86_64 one" {
	local a
	for a in aarch64 x86_64; do
		standin_release "$SB/$a" 7.0.0 "lendk-$a-apple-darwin.tar.gz"
		rm -rf "$HOME" && mkdir -p "$HOME"
		platform Darwin x86_64 "$([[ $a == aarch64 ]] && echo 1)"
		REL=$SB/$a inst
		assert_eq "$final" "lendk-install: ok: lendk 7.0.0 installed to $HOME/.local/bin/lendk"
		grep -qF "$MARK" "$HOME/.local/bin/lendk"
	done
}

@test "installer: another OS or CPU is unsupported-os, naming it and the from-source route" {
	platform Linux riscv64
	binst
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: unsupported-os: Linux riscv64 is not supported; lendk ships binaries for Linux and macOS on x86_64 and arm64, and builds from source elsewhere: https://github.com/v-bonilla/lendk#from-source"
	refute_contains "$output" cargo
	platform FreeBSD amd64
	binst
	assert_eq "$final" "lendk-install: unsupported-os: FreeBSD amd64 is not supported; lendk ships binaries for Linux and macOS on x86_64 and arm64, and builds from source elsewhere: https://github.com/v-bonilla/lendk#from-source"
	nothing_installed
	# While a release carries the 1.x script, it still installs on another CPU.
	platform Linux riscv64
	inst
	assert_eq "$status" 0
}

@test "installer: a binary install without sha256sum or shasum is missing-deps and never skips the check" {
	mkdir "$SB/sys"
	find "$SYS" -mindepth 1 -maxdepth 1 ! -name sha256sum ! -name shasum -exec ln -s {} "$SB/sys/" \;
	SYS=$SB/sys binst
	assert_eq "$status" 1
	assert_eq "$final" "lendk-install: missing-deps: missing: sha256sum; no supported package manager found, install them by hand"
	nothing_installed
	[[ $output != *downloading* ]]
}

@test "installer: each check failing on the binary installs nothing" {
	local t=$SB/t v=$SB/t/lendk-7.0.0 r=$SB/r
	mkdir -p "$v/bin"
	standin "$v/bin/lendk" 7.0.0
	# The archive's SHA-256.
	cp -R "$BREL" "$r"
	printf '%064d  %s\n' 0 "$ASSET" >"$r/latest/download/SHA256SUMS"
	REL=$r inst
	assert_eq "$final" "lendk-install: checksum: $ASSET has SHA-256 $(sha256 "$BREL/latest/download/$ASSET" | cut -d' ' -f1), SHA256SUMS lists '$(printf '%064d' 0)'; nothing was installed"
	nothing_installed
	# Exactly one lendk-X.Y.Z/bin/lendk.
	mkdir -p "$t/lendk-7.0.1/bin" && cp "$v/bin/lendk" "$t/lendk-7.0.1/bin/"
	pack "$t" "$SB/two"
	REL=$SB/two inst
	assert_eq "$final" "lendk-install: install: $ASSET holds no single lendk-X.Y.Z/bin/lendk; nothing was installed"
	rm -r "$t/lendk-7.0.1" && mv "$v" "$t/lendk-7.0"
	pack "$t" "$SB/none"
	REL=$SB/none inst
	assert_eq "$final" "lendk-install: install: $ASSET holds no single lendk-X.Y.Z/bin/lendk; nothing was installed"
	mv "$t/lendk-7.0" "$v"
	# The marker.
	sed_file 2d "$v/bin/lendk"
	pack "$t" "$SB/mark"
	REL=$SB/mark inst
	assert_eq "$final" "lendk-install: install: lendk-7.0.0/bin/lendk in $ASSET is not a lendk binary; nothing was installed"
	nothing_installed
	# The staged run: failing, or printing another version than the member's.
	standin "$v/bin/lendk" 7.0.1
	pack "$t" "$SB/other"
	printf '#!/bin/sh\n# %s\nexit 1\n' "$MARK" >"$v/bin/lendk"
	pack "$t" "$SB/fails"
	for r in other fails; do
		REL=$SB/$r inst
		assert_eq "$final" "lendk-install: install: the downloaded lendk does not run on $PLATFORM; nothing was installed"
		nothing_installed
	done
	# The version asked for.
	standin "$v/bin/lendk" 7.0.0
	pack "$t" "$SB/ask"
	mkdir -p "$SB/ask/download" && mv "$SB/ask/latest/download" "$SB/ask/download/v7.0.2"
	REL=$SB/ask inst --version 7.0.2
	assert_eq "$final" "lendk-install: install: the release for 7.0.2 holds lendk 7.0.0"
	nothing_installed
}

@test "installer: over a 1.x install, the login block loses its bash line and the existing shims run the binary" {
	mkdir -p "$SB/good"
	ln -s "$BASH" "$SB/good/bash"
	rm "$STUB/bash"
	stub bash 'exit 1'
	status=0
	env -i HOME="$HOME" PATH="$STUB:$SB/good:$SYS" SHELL=/bin/bash TMPDIR="$TMPDIR" PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" \
		LENDK_INSTALL_BASE_URL="file://$REL" sh "$ROOT/install.sh" </dev/null >/dev/null 2>&1
	grep -qF "'$SB/good'" "$HOME/.profile"
	ln -s "$FIXTURES/stub-target" "$SB/bin/gh"
	env PATH="$SB/good:$SB/bin:$PATH" "$HOME/.local/bin/lendk" add gh GH_TOKEN >/dev/null 2>&1
	[[ -f $SHIMS/gh ]]
	standin_release "$SB/b" 7.0.0
	REL=$SB/b inst
	assert_eq "$final" "lendk-install: ok: lendk 7.0.0 installed to $HOME/.local/bin/lendk"
	refute_contains "$(<"$HOME/.profile")" "$SB/good"
	assert_eq "$(grep -c '^# >>> lendk-install >>>$' "$HOME/.profile")" 1
	mkdir -p "$STUB_LOG"
	STUB_LOG=$STUB_LOG "$SHIMS/gh" >/dev/null 2>&1 || true
	assert_eq "$(<"$STUB_LOG/standin")" "$HOME/.local/bin/lendk run -- gh"
}

# bats test_tags=docker
@test "installer: under bash 3.2 it installs the binary, and stops on missing deps for 1.x" {
	require docker
	status=0
	output=$(docker run --rm --pull never -u "$(id -u):$(id -g)" -e HOME=/tmp -e LENDK_INSTALL_BASE_URL=file:///rel \
		-v "$ROOT/install.sh:/install.sh:ro" -v "$REL:/rel:ro" bash:3.2.57 bash /install.sh --yes 2>&1 </dev/null) || status=$?
	assert_eq "$status" 1
	assert_eq "${output##*$'\n'}" 'lendk-install: missing-deps: missing: bash>=4.4 gnupg>=2.4 pass; run: sudo apk add --no-cache bash gnupg pass (or rerun with --install-deps)'
	status=0
	output=$(docker run --rm --pull never -u "$(id -u):$(id -g)" -e HOME=/tmp -e LENDK_INSTALL_BASE_URL=file:///rel \
		-v "$ROOT/install.sh:/install.sh:ro" -v "$BREL:/rel:ro" bash:3.2.57 \
		sh -c 'bash /install.sh --yes && /tmp/.local/bin/lendk --version' 2>&1 </dev/null) || status=$?
	[[ $status == 0 ]] || { echo "$output" >&2; return 1; }
	assert_line "$output" "lendk-install: ok: lendk $RUNNING installed to /tmp/.local/bin/lendk"
	assert_eq "${output##*$'\n'}" "lendk $RUNNING"
}

# bats test_tags=docker
@test "installer: installs end to end under dash on Ubuntu and busybox sh on Alpine" {
	require docker
	local image shell rel v
	mkdir -p "$SB/cstub"
	cp "$STUB/gpg" "$STUB/pass" "$STUB/curl" "$SB/cstub/"
	for image in lendk-test:ubuntu:dash lendk-test:bash44:sh; do
		shell=${image##*:}
		image=${image%:*}
		for rel in "$REL:$VERSION" "$BREL:$RUNNING"; do
			v=${rel##*:}
			rel=${rel%:*}
			status=0
			output=$(docker run --rm --pull never -u "$(id -u):$(id -g)" -e HOME=/tmp/h -e LENDK_INSTALL_BASE_URL=file:///rel \
				-e PATH=/stub:/usr/local/bin:/usr/bin:/bin -v "$ROOT/install.sh:/install.sh:ro" -v "$rel:/rel:ro" -v "$SB/cstub:/stub:ro" \
				"$image" sh -c "mkdir -p /tmp/h && $shell /install.sh --yes && env -i HOME=/tmp/h PATH=/usr/local/bin:/usr/bin:/bin bash -lc 'command -v lendk'" 2>&1 </dev/null) || status=$?
			[[ $status == 0 ]] || { echo "$image: $output" >&2; return 1; }
			assert_line "$output" "lendk-install: ok: lendk $v installed to /tmp/h/.local/bin/lendk"
			assert_eq "${output##*$'\n'}" /tmp/h/.local/bin/lendk
		done
	done
}
