#!/usr/bin/env bats
# FR45 to FR50, AC7: upgrade, run on a copy of lendk installed in the sandbox, against fixture releases
# served from file:// or, for https://, by stub download tools.
# shellcheck disable=SC2012,SC2016,SC2030,SC2031,SC2034

setup_file() {
	load helpers/common
	export BATS_LENDK_REL=$BATS_FILE_TMPDIR/rel BATS_LENDK_SUM
	BATS_LENDK_SUM=$(cksum <"$ROOT/bin/lendk")
	release "$BATS_LENDK_REL/new" 99.0.0
	release "$BATS_LENDK_REL/same" "$(sed -n 's/^LENDK_VERSION=//p' "$ROOT/bin/lendk")"
	release "$BATS_LENDK_REL/old" 0.0.1
	release "$BATS_LENDK_REL/ten" 10.0.0
	release "$BATS_LENDK_REL/nines" 9.9.9
}

setup() {
	load helpers/common
	sandbox
	REL=$BATS_LENDK_REL
	VERSION=$(sed -n 's/^LENDK_VERSION=//p' "$ROOT/bin/lendk")
	BIN=$HOME/.local/bin
	MAP=$HOME/.config/lendk/map
	SHIMS=$HOME/.local/share/lendk/shims
	mkdir -p "$BIN" "$HOME/.config/lendk" && chmod 700 "$HOME/.config/lendk"
	cp "$ROOT/bin/lendk" "$BIN/lendk"
	chmod 755 "$BIN/lendk"
	LENDK=$BIN/lendk
	NOTICE=
	mark
}

teardown() {
	assert_eq "$(cksum <"$ROOT/bin/lendk")" "$BATS_LENDK_SUM"
}

inode() { ls -i "$1" | awk '{ print $1 }'; }

# mark: remember lendk's checksum and inode.
mark() {
	SUM=$(cksum <"$LENDK")
	INODE=$(inode "$LENDK")
}

# unchanged: lendk's file is the one mark saw, alone in its directory, and TMPDIR is empty.
unchanged() {
	assert_eq "$(cksum <"$LENDK")" "$SUM"
	assert_eq "$(inode "$LENDK")" "$INODE"
	assert_eq "$(ls -A "$BIN")" lendk
	assert_eq "$(ls -A "$TMPDIR")" ""
}

# nothing TEXT: the call changed nothing and its stderr is the notice for a set base, if it got that
# far, then the one upgrade line with TEXT.
nothing() {
	assert_eq "$stderr" "${NOTICE:+$NOTICE$'\n'}lendk: upgrade: $1. Stop and ask the user."
	assert_class upgrade 125
	assert_eq "$output" ""
	unchanged
}

# base DIR: serve the release under DIR from file://.
base() {
	export LENDK_INSTALL_BASE_URL=file://$1
	NOTICE="lendk: notice: the release comes from file://$1, set by LENDK_INSTALL_BASE_URL."
}

# web NAME [MODE]: serve $REL/NAME from https://releases.test/NAME through a stub curl in MODE.
web() {
	export LENDK_INSTALL_BASE_URL=https://releases.test/$1
	NOTICE="lendk: notice: the release comes from https://releases.test/$1, set by LENDK_INSTALL_BASE_URL."
	tool curl "${2-}"
}

# tool NAME [MODE]: a stub download tool NAME first on PATH. It logs its arguments and environment
# under $STUB_LOG/NAME.PID, then copies the file its URL names under $REL to its output argument.
# It also records what it reads from stdin, and appends its arguments to $STUB_LOG/calls.NAME.
# MODE: fail exits 22; half writes half of the archive; noisy also writes to stdout and stderr; hang
# never returns; stubborn also ignores TERM; killjob kills the process that started it; https makes
# --help list --https-only, and bighelp does so ahead of more text than a pipe holds.
tool() {
	printf '#!/bin/sh\nname=%s mode=%s rel=%s\n' "$1" "${2-}" "$REL" >"$SB/bin/$1"
	cat >>"$SB/bin/$1" <<'EOF'
if [ "${1-}" = --help ]; then
	echo "Usage: $name [OPTION]... [URL]..."
	case $mode in https | bighelp) echo "       --https-only                only follow secure HTTPS links" ;; esac
	i=0
	while [ "$mode" = bighelp ] && [ "$i" -lt 3000 ]; do
		echo "       --filler-option-$i            pads the help text past what a pipe holds"
		i=$((i + 1))
	done
	exit 0
fi
log=$STUB_LOG/$name.$$
path=$PATH
PATH=$PATH:/usr/bin:/bin
mkdir -p "$log"
printf '%s\n' "$*" >"$log/argv"
printf '%s\n' "$*" >>"$STUB_LOG/calls.$name"
PATH=$path "$(command -v env)" >"$log/env"
cat >"$log/stdin"
out='' prev='' url=''
for a in "$@"; do
	case $prev in -o | -O) out=$a ;; esac
	prev=$a url=$a
done
case $url in
https://github.com/v-bonilla/lendk/releases/*) src=$rel/new/${url#*/releases/} ;;
*) src=$rel/${url#https://releases.test/} ;;
esac
case $mode in
fail) exit 22 ;;
half) case $url in *.tar.gz) head -c "$(($(wc -c <"$src") / 2))" "$src" >"$out" && exit 0 ;; esac ;;
noisy)
	echo "$name: noise on stdout"
	echo "$name: noise on stderr" >&2
	;;
hang) sleep 3600 ;;
killjob)
	kill -KILL "$PPID"
	exit 1
	;;
stubborn)
	trap '' TERM
	sleep 3600
	;;
esac
cp "$src" "$out"
EOF
	chmod +x "$SB/bin/$1"
}

# toolbox SKIP...: $SB/min, holding bash and the tools upgrade needs from PATH, except SKIP.
toolbox() {
	local t
	rm -rf "$SB/min"
	mkdir "$SB/min"
	for t in bash tar gzip sha256sum shasum; do
		[[ " $* " == *" $t "* ]] || ! command -v "$t" >/dev/null || ln -s "$(command -v "$t")" "$SB/min/$t"
	done
}

# candidate NAME VERSION LINE...: serve a release whose lendk-VERSION/bin/lendk is a bash script with
# lendk's second line, then each LINE.
candidate() {
	local d=$SB/cand-$1/lendk-$2/bin
	mkdir -p "$d"
	{
		printf '#!/usr/bin/env bash\n%s\n' "$(sed -n 2p "$ROOT/bin/lendk")"
		printf '%s\n' "${@:3}"
	} >"$d/lendk"
	pack "$SB/cand-$1" "$SB/rel-$1"
	base "$SB/rel-$1"
}

# ppid_of PID: its parent's PID.
ppid_of() {
	local stat
	if [[ -d /proc/self ]]; then
		read -r stat <"/proc/$1/stat"
		stat=${stat##*) }
		# shellcheck disable=SC2086
		set -- $stat
		printf '%s\n' "$2"
	else
		ps -o ppid= -p "$1" | tr -d ' '
	fi
}

# calls NAME: the stub NAME's argument lines, sorted.
calls() { cat "$SB"/log/"$1".*/argv 2>/dev/null | LC_ALL=C sort; }

# sum FILE: its SHA-256.
sum() { sha256 "$1" | cut -d ' ' -f 1; }

@test "FR45, NFR5: upgrade replaces lendk with the latest release and touches nothing else" {
	local before after
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	printf 'stub K1\n' >"$MAP" && chmod 600 "$MAP"
	printf '%s\n' "$SENTINEL" >"$SB/store/env/K1.gpg"
	run_lendk sync
	assert_eq "$status" 0
	assert_eq "$(sed -n 2p "$LENDK")" "$(sed -n "s/^upgrade_mark='\(.*\)'$/\1/p" "$LENDK")"
	before=$(snapshot | grep -v "^$LENDK \|^$SHIMS")
	base "$REL/new"
	run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$output" "upgraded lendk $VERSION to 99.0.0 at $LENDK"
	assert_eq "$stderr" "$NOTICE"
	cmp "$LENDK" "$REL/new.src/lendk-99.0.0/bin/lendk"
	assert_eq "$(ls -ln "$LENDK" | cut -c1-10)" -rwxr-xr-x
	[[ $(inode "$LENDK") != "$INODE" ]]
	assert_eq "$("$LENDK" --version)" "lendk 99.0.0"
	after=$(snapshot | grep -v "^$LENDK \|^$SHIMS")
	assert_eq "$after" "$before"
	assert_eq "$(ls -A "$BIN")" lendk
	assert_eq "$(ls -A "$TMPDIR")" ""
	assert_eq "$(ls -A "$SHIMS")" stub
	[[ ! -e $SHIMS.lock ]]
	assert_eq "$(compgen -G "$SB/log/pass.*")" ""
}

@test "FR45: an argument is usage, stdin is never read, and a terminal changes only the FIX" {
	local never
	base "$REL/new"
	run_lendk upgrade x
	assert_eq "$stderr" "lendk: usage: upgrade takes no arguments. See: lendk --help"
	assert_class usage 2
	unchanged
	assert_eq "$(printf 'kept\n' | { "$LENDK" upgrade >/dev/null 2>&1; cat; })" kept
	assert_eq "$("$LENDK" --version)" "lendk 99.0.0"
	mv "$LENDK" "$SB/real"
	ln -s "$SB/real" "$LENDK"
	LENDK_PROMPT=never run_lendk upgrade
	assert_class upgrade 125
	never=$stderr
	LENDK_PROMPT=allow run_lendk upgrade
	assert_class upgrade 125
	assert_eq "$never" "lendk: upgrade: $LENDK is a symlink, so another tool manages this install. Stop and ask the user."
	assert_eq "$stderr" "lendk: upgrade: $LENDK is a symlink, so another tool manages this install. Upgrade lendk the way it was installed."
}

@test "FR46: an https base goes through curl with https-only options" {
	web new
	run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$stderr" "$NOTICE"
	assert_eq "$output" "upgraded lendk $VERSION to 99.0.0 at $LENDK"
	local lines
	mapfile -t lines < <(calls curl)
	assert_eq "${#lines[@]}" 2
	[[ ${lines[0]} == "-fsSL --proto =https --tlsv1.2 -o $TMPDIR/lendk."??????"/SHA256SUMS https://releases.test/new/latest/download/SHA256SUMS" ]]
	[[ ${lines[1]} == "-fsSL --proto =https --tlsv1.2 -o $TMPDIR/lendk."??????"/lendk.tar.gz https://releases.test/new/latest/download/lendk.tar.gz" ]]
	cmp "$LENDK" "$REL/new.src/lendk-99.0.0/bin/lendk"
}

@test "FR46: without curl, wget downloads, with --https-only where it has it" {
	local mode opt lines
	toolbox
	rm "$SB/bin/curl"
	export LENDK_INSTALL_BASE_URL=https://releases.test/new
	for mode in https bighelp plain; do
		cp "$ROOT/bin/lendk" "$LENDK"
		rm -rf "$SB/log"/*
		tool wget "$mode"
		opt=
		[[ $mode == plain ]] || opt=' --https-only'
		PATH=$SB/bin:$SB/min run_lendk upgrade
		assert_eq "$status" 0
		mapfile -t lines < <(calls wget)
		assert_eq "${#lines[@]}" 2
		[[ ${lines[0]} == "-q$opt -O $TMPDIR/lendk."??????"/SHA256SUMS https://releases.test/new/latest/download/SHA256SUMS" ]]
		[[ ${lines[1]} == "-q$opt -O $TMPDIR/lendk."??????"/lendk.tar.gz https://releases.test/new/latest/download/lendk.tar.gz" ]]
		assert_eq "$("$LENDK" --version)" "lendk 99.0.0"
	done
}

@test "FR46: a base that is not https:// or file:///, or holds a blank, is usage, and a set base is named in a notice" {
	local v
	tool curl
	for v in http://releases.test/new ftp://releases.test/new "file://${REL#/}/new" "file://$REL/new x" $'https://releases.test/new\tx' $'https://releases.test/new\001x'; do
		LENDK_INSTALL_BASE_URL=$v run_lendk upgrade
		assert_eq "$stderr" "lendk: usage: LENDK_INSTALL_BASE_URL is '${v//[![:graph:]]/?}'; use an https:// or file:/// URL. See: lendk --help"
		assert_class usage 2
		assert_eq "$output" ""
		unchanged
	done
	assert_eq "$(calls curl)" ""
	base "$REL/same"
	run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$stderr" "lendk: notice: the release comes from file://$REL/same, set by LENDK_INSTALL_BASE_URL."
}

@test "FR46, NFR4: a missing tool is upgrade before anything is fetched, and a file base needs no curl or wget" {
	local t
	for t in tar gzip sha256sum; do
		toolbox "$t" shasum
		LENDK_INSTALL_BASE_URL=file://$REL/new PATH=$SB/min run_lendk upgrade
		nothing "$t is not on PATH outside $SHIMS"
	done
	toolbox
	LENDK_INSTALL_BASE_URL=https://releases.test/new PATH=$SB/min run_lendk upgrade
	nothing "curl is not on PATH outside $SHIMS"
	LENDK_INSTALL_BASE_URL=file://$REL/new PATH=$SB/min run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$output" "upgraded lendk $VERSION to 99.0.0 at $LENDK"
}

@test "FR46: a mapped curl runs without its shim and gets no key, and the tools' output stays out" {
	local log
	printf 'curl K1\n' >"$MAP" && chmod 600 "$MAP"
	printf '%s\n' "$SENTINEL" >"$SB/store/env/K1.gpg"
	run_lendk sync
	assert_eq "$status" 0
	[[ -x $SHIMS/curl ]]
	web new noisy
	PATH=$SHIMS:$PATH run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$stderr" "$NOTICE"
	assert_eq "$output" "upgraded lendk $VERSION to 99.0.0 at $LENDK"
	assert_eq "$(compgen -G "$SB/log/pass.*")" ""
	assert_eq "$(calls curl | wc -l)" 2
	for log in "$SB"/log/curl.*; do
		refute_contains "$(grep '^PATH=' "$log/env")" "$SHIMS"
		refute_contains "$(<"$log/env")" K1=
		refute_contains "$(<"$log/env")" "$SENTINEL"
	done
}

@test "FR47: a failed download and one cut short change nothing" {
	local half
	web new fail
	run_lendk upgrade
	nothing "cannot download https://releases.test/new/latest/download/lendk.tar.gz"
	web new half
	run_lendk upgrade
	head -c "$(($(wc -c <"$REL/new/latest/download/lendk.tar.gz") / 2))" "$REL/new/latest/download/lendk.tar.gz" >"$SB/half"
	nothing "lendk.tar.gz has SHA-256 $(sum "$SB/half"), but SHA256SUMS lists $(sum "$REL/new/latest/download/lendk.tar.gz")"
	base "$SB/none"
	run_lendk upgrade
	nothing "cannot download file://$SB/none/latest/download/lendk.tar.gz"
}

@test "FR47: another checksum, or SHA256SUMS without the asset, changes nothing" {
	local got
	cp -R "$REL/new" "$SB/rel"
	got=$(sum "$SB/rel/latest/download/lendk.tar.gz")
	printf '%064d  lendk.tar.gz\n' 0 >"$SB/rel/latest/download/SHA256SUMS"
	base "$SB/rel"
	run_lendk upgrade
	nothing "lendk.tar.gz has SHA-256 $got, but SHA256SUMS lists $(printf '%064d' 0)"
	printf '%s  other.tar.gz\n' "$got" >"$SB/rel/latest/download/SHA256SUMS"
	run_lendk upgrade
	nothing "lendk.tar.gz has SHA-256 $got, but SHA256SUMS lists nothing"
}

@test "FR47: an archive without lendk, or holding a file that is not lendk, changes nothing" {
	mkdir -p "$SB/a/lendk-99.0.0" "$SB/b/lendk-99.0.0/bin" "$SB/c/lendk-99.0.0/bin" "$SB/c/lendk-98.0.0/bin"
	cp "$ROOT/LICENSE" "$SB/a/lendk-99.0.0/"
	sed '2s/.*/# another tool/' "$REL/new.src/lendk-99.0.0/bin/lendk" >"$SB/b/lendk-99.0.0/bin/lendk"
	cp "$REL/new.src/lendk-99.0.0/bin/lendk" "$SB/c/lendk-99.0.0/bin/lendk"
	cp "$REL/new.src/lendk-99.0.0/bin/lendk" "$SB/c/lendk-98.0.0/bin/lendk"
	mkdir -p "$SB/d/lendk-99.0.0/bin" "$SB/e/lendk-99.0.0/bin/lendk"
	cp "$REL/new.src/lendk-99.0.0/bin/lendk" "$SB/d/lendk-99.0.0/lendk.real"
	ln -s ../lendk.real "$SB/d/lendk-99.0.0/bin/lendk"
	cp "$REL/new.src/lendk-99.0.0/bin/lendk" "$SB/e/lendk-99.0.0/bin/lendk/lendk"
	local r
	for r in a b c d e; do
		pack "$SB/$r" "$SB/rel-$r"
		base "$SB/rel-$r"
		run_lendk upgrade
		nothing "lendk.tar.gz holds no lendk-X.Y.Z/bin/lendk"
	done
}

@test "FR47: a lendk that does not run under this bash changes nothing" {
	mkdir -p "$SB/a/lendk-99.0.0/bin"
	printf '#!/usr/bin/env bash\n%s\nexit 125\n' "$(sed -n 2p "$LENDK")" >"$SB/a/lendk-99.0.0/bin/lendk"
	pack "$SB/a" "$SB/rel"
	base "$SB/rel"
	run_lendk upgrade
	nothing "the downloaded lendk does not run under bash $(bash -c 'printf %s "${BASH_VERSION%%[!0-9.]*}"')"
}

@test "FR47: a candidate that exits non-zero, or prints anything but lendk X.Y.Z, changes nothing" {
	local body n=0 v
	v=$(bash -c 'printf %s "${BASH_VERSION%%[!0-9.]*}"')
	for body in 'echo "lendk 99.0.0"; exit 1' 'echo "x lendk 99.0.0"' 'echo "lendk 99.0.0 x"' 'echo "lendk 99.0.0"; echo more' \
		'echo "lendk 99.00.0"' 'echo "lendk 099.0.0"' 'echo "lendk 99.0.9999999999"'; do
		n=$((n + 1))
		candidate "$n" 99.0.0 "$body"
		run_lendk upgrade
		nothing "the downloaded lendk does not run under bash $v"
	done
}

@test "FR47: the member's directory and --version name one version, written without leading zeros or overflow" {
	candidate a 99.0.0 'echo "lendk 98.0.0"'
	run_lendk upgrade
	nothing "lendk.tar.gz holds no lendk-98.0.0/bin/lendk"
	local v
	for v in 099.0.0 99.00.0 99999999999999999999.0.0 9999999999.0.0; do
		candidate "$v" "$v" "echo 'lendk $v'"
		run_lendk upgrade
		nothing "lendk.tar.gz holds no lendk-X.Y.Z/bin/lendk"
	done
}

@test "FR47: an archive that does not unpack, or a fetch that ends without a result, is a local failure" {
	mkdir -p "$SB/rel/latest/download"
	printf 'not an archive\n' >"$SB/rel/latest/download/lendk.tar.gz"
	(cd "$SB/rel/latest/download" && sha256 lendk.tar.gz >SHA256SUMS)
	base "$SB/rel"
	run_lendk upgrade
	nothing "$TMPDIR: cannot unpack lendk.tar.gz"
	# The listing works and the extraction fails.
	toolbox tar
	printf '#!/bin/sh\n[ "$1" != -xOf ] || exit 2\nexec %s "$@"\n' "$(command -v tar)" >"$SB/min/tar"
	chmod +x "$SB/min/tar"
	base "$REL/new"
	PATH=$SB/min run_lendk upgrade
	nothing "$TMPDIR: cannot unpack lendk.tar.gz"
	web new killjob
	run_lendk upgrade
	nothing "$TMPDIR: the fetch ended without a result"
	LENDK_PROMPT=allow run_lendk upgrade
	assert_eq "$stderr" "$NOTICE"$'\n'"lendk: upgrade: $TMPDIR: the fetch ended without a result. Fix it, then run: lendk upgrade"
	assert_class upgrade 125
	unchanged
}

@test "FR46: no other verb reads LENDK_INSTALL_BASE_URL" {
	local verb out err rc
	for verb in check sync; do
		run_lendk "$verb"
		out=$output err=$stderr rc=$status
		LENDK_INSTALL_BASE_URL=http://releases.test/new run_lendk "$verb"
		assert_eq "$status" "$rc"
		assert_eq "$output" "$out"
		assert_eq "$stderr" "$err"
		refute_contains "$stderr" LENDK_INSTALL_BASE_URL
	done
	assert_eq "$rc" 0
}

@test "FR46, NFR4: with shasum and no sha256sum the upgrade succeeds" {
	toolbox sha256sum shasum
	if command -v sha256sum >/dev/null; then
		printf '#!/bin/sh\necho "$*" >>"$STUB_LOG/calls.shasum"\n[ "$1" = -a ] && [ "$2" = 256 ] || exit 2\nexec %s "$3"\n' "$(command -v sha256sum)" >"$SB/min/shasum"
	else
		printf '#!/bin/sh\necho "$*" >>"$STUB_LOG/calls.shasum"\nexec %s "$@"\n' "$(command -v shasum)" >"$SB/min/shasum"
	fi
	chmod +x "$SB/min/shasum"
	base "$REL/new"
	PATH=$SB/min run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$output" "upgraded lendk $VERSION to 99.0.0 at $LENDK"
	[[ $(<"$SB/log/calls.shasum") == "-a 256 $TMPDIR/lendk."??????"/lendk.tar.gz" ]]
}

@test "FR46: the tools get /dev/null as stdin" {
	local f
	printf '#!/bin/sh\ncat >>"$STUB_LOG/gzip.stdin"\necho call >>"$STUB_LOG/gzip.calls"\nexec %s "$@"\n' "$(command -v gzip)" >"$SB/bin/gzip"
	chmod +x "$SB/bin/gzip"
	web new
	printf 'kept\n' | { "$LENDK" upgrade >/dev/null 2>&1; cat >"$SB/rest"; }
	assert_eq "$(<"$SB/rest")" kept
	assert_eq "$("$LENDK" --version)" "lendk 99.0.0"
	assert_eq "$(wc -l <"$SB/log/gzip.calls")" 2
	assert_eq "$(calls curl | wc -l)" 2
	for f in "$SB"/log/curl.*/stdin "$SB/log/gzip.stdin"; do
		[[ -f $f && ! -s $f ]]
	done
}

@test "FR46: an unset or empty LENDK_INSTALL_BASE_URL is the project's releases, with no notice" {
	local how lines
	toolbox
	for how in unset empty; do
		cp "$ROOT/bin/lendk" "$LENDK"
		rm -rf "$SB/log"/*
		tool curl
		unset LENDK_INSTALL_BASE_URL
		[[ $how == unset ]] || export LENDK_INSTALL_BASE_URL=
		PATH=$SB/bin:$SB/min run_lendk upgrade
		assert_eq "$status" 0
		assert_eq "$stderr" ""
		assert_eq "$output" "upgraded lendk $VERSION to 99.0.0 at $LENDK"
		mapfile -t lines <"$SB/log/calls.curl"
		assert_eq "${#lines[@]}" 2
		assert_eq "${lines[0]##* }" https://github.com/v-bonilla/lendk/releases/latest/download/lendk.tar.gz
		assert_eq "${lines[1]##* }" https://github.com/v-bonilla/lendk/releases/latest/download/SHA256SUMS
	done
}

@test "FR47: a release that is not newer is up to date, also for an install ahead of it, compared number by number" {
	base "$REL/same"
	run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$output" "lendk $VERSION is up to date: the latest release is $VERSION"
	assert_eq "$stderr" "$NOTICE"
	unchanged
	base "$REL/old"
	run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$output" "lendk $VERSION is up to date: the latest release is 0.0.1"
	unchanged
	sed 's/^LENDK_VERSION=.*/LENDK_VERSION=9.0.0/' "$ROOT/bin/lendk" >"$LENDK"
	base "$REL/ten"
	LENDK_PROMPT=allow run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$output" "upgraded lendk 9.0.0 to 10.0.0 at $LENDK"
	mark
	base "$REL/nines"
	run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$output" "lendk 10.0.0 is up to date: the latest release is 9.9.9"
	unchanged
}

@test "FR48: a symlinked lendk is refused before any fetch" {
	mkdir "$SB/v1"
	mv "$LENDK" "$SB/v1/lendk"
	ln -s "$SB/v1/lendk" "$LENDK"
	mark
	web new
	NOTICE=
	run_lendk upgrade
	nothing "$LENDK is a symlink, so another tool manages this install"
	assert_eq "$(calls curl)" ""
	[[ -L $LENDK ]]
	assert_eq "$(ls -A "$SB/v1")" lendk
}

@test "FR48: a file that is not lendk's, or a directory the user cannot write, is refused before any fetch" {
	[[ $(id -u) != 0 ]] || skip "root writes to any directory"
	web new
	NOTICE=
	chmod 555 "$BIN"
	run_lendk upgrade
	chmod 755 "$BIN"
	nothing "$BIN cannot be written"
	sed '2s/.*/# another tool/' "$ROOT/bin/lendk" >"$LENDK"
	mark
	run_lendk upgrade
	nothing "$LENDK is not lendk's own file"
	assert_eq "$(calls curl)" ""
}

@test "FR48: an install whose version is not X.Y.Z is refused before any fetch" {
	local v
	web new
	NOTICE=
	for v in 1.1.0-dev 01.0.0 1.0 9999999999.0.0; do
		sed "s/^LENDK_VERSION=.*/LENDK_VERSION=$v/" "$ROOT/bin/lendk" >"$LENDK"
		mark
		run_lendk upgrade
		nothing "$LENDK has version $v, not a release's X.Y.Z"
	done
	assert_eq "$(calls curl)" ""
}

@test "FR49: the upgrade is a rename: a new inode, and an open descriptor keeps the old bytes" {
	local fd
	exec {fd}<"$LENDK"
	base "$REL/new"
	run_lendk upgrade
	assert_eq "$status" 0
	[[ $(inode "$LENDK") != "$INODE" ]]
	cmp - "$ROOT/bin/lendk" <&"$fd"
	exec {fd}<&-
	cmp "$LENDK" "$REL/new.src/lendk-99.0.0/bin/lendk"
	assert_eq "$(ls -A "$BIN")" lendk
}

@test "FR49: two upgrades at once, and add calls alongside, all succeed and leave one whole file" {
	local i p pids=()
	base "$REL/new"
	for i in 1 2; do
		"$LENDK" upgrade </dev/null >"$SB/up.$i" 2>&1 &
		pids+=("$!")
	done
	for i in 1 2 3 4 5; do
		ln -s "$FIXTURES/stub-target" "$SB/bin/c$i"
		"$LENDK" add "c$i" "K$i" </dev/null >/dev/null 2>&1 &
		pids+=("$!")
	done
	for p in "${pids[@]}"; do
		wait "$p"
	done
	assert_eq "$(sort "$MAP")" $'c1 K1\nc2 K2\nc3 K3\nc4 K4\nc5 K5'
	assert_eq "$(ls -A "$SHIMS" | sort | tr '\n' ' ')" "c1 c2 c3 c4 c5 "
	cmp "$LENDK" "$REL/new.src/lendk-99.0.0/bin/lendk"
	assert_eq "$(ls -A "$BIN")" lendk
	assert_eq "$(ls -A "$TMPDIR")" ""
	[[ ! -e $SHIMS.lock ]]
	for i in 1 2; do
		grep -qx -e "upgraded lendk $VERSION to 99.0.0 at $LENDK" -e "lendk 99.0.0 is up to date: the latest release is 99.0.0" "$SB/up.$i"
	done
}

@test "FR49: sync runs through the new file, and with an invalid map line the upgrade stands" {
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	printf 'stub K1\n' >"$MAP" && chmod 600 "$MAP"
	base "$REL/new"
	run_lendk upgrade
	assert_eq "$status" 0
	grep -qxF "lendk='$LENDK'" "$SHIMS/stub"
	cp "$ROOT/bin/lendk" "$LENDK"
	printf 'stub K1\ngh 1BAD\n' >"$MAP"
	run_lendk upgrade
	assert_eq "$output" "upgraded lendk $VERSION to 99.0.0 at $LENDK"
	assert_eq "$stderr" "$NOTICE"$'\n'"lendk: map: $MAP:2: '1BAD' is not a valid key name. Stop and ask the user."
	assert_class map 125
	assert_eq "$("$LENDK" --version)" "lendk 99.0.0"
	assert_eq "$(ls -A "$BIN")" lendk
}

# start_upgrade MODE: start lendk upgrade in its own process group against a stub curl in MODE, and
# return once the tool runs; lpid is lendk's PID and group.
start_upgrade() {
	local i
	rm -rf "$SB/log"/*
	web new "$1"
	set -m
	LENDK_TEST_FAMILY=$SENTINEL "$LENDK" upgrade </dev/null >"$SB/stdout" 2>"$SB/stderr" &
	lpid=$!
	set +m
	for ((i = 0; i < 50; i++)); do
		[[ -z $(compgen -G "$SB/log/curl.*/env") ]] || return 0
		sleep 0.1
	done
	echo "the download tool did not start" >&2
	return 1
}

# stopped: within 2 s nothing of the call is left, and lendk kept its file and said no more.
stopped() {
	none_within 2
	wait "$lpid" 2>/dev/null || true
	assert_eq "$(<"$SB/stderr")" "$NOTICE"
	assert_eq "$(<"$SB/stdout")" ""
	unchanged
}

@test "FR50: a download that never returns gives upgrade after LENDK_TIMEOUT and before LENDK_TIMEOUT + 2 s" {
	local mode
	for mode in hang stubborn; do
		rm -rf "$SB/log"/*
		web new "$mode"
		LENDK_TIMEOUT=2 LENDK_TEST_FAMILY=$SENTINEL timed_lendk upgrade
		nothing "fetching the release did not finish within 2 s"
		within 2 4
		none_within 2
		assert_eq "$(calls curl | wc -l)" 1
	done
}

@test "FR50: a candidate whose --version never returns gives upgrade within LENDK_TIMEOUT + 2 s and leaves nothing" {
	local body n=0
	for body in 'sleep 3600' 'trap "" TERM; sleep 3600'; do
		n=$((n + 1))
		candidate "$n" 99.0.0 "$body"
		LENDK_TIMEOUT=2 LENDK_TEST_FAMILY=$SENTINEL timed_lendk upgrade
		nothing "fetching the release did not finish within 2 s"
		within 2 4
		none_within 2
	done
}

@test "FR50: TERM, INT, HUP or KILL during the fetch leaves no tool, watchdog, temporary directory or staged file" {
	local sig mode
	for mode in hang stubborn; do
		for sig in TERM INT HUP KILL; do
			start_upgrade "$mode"
			kill "-$sig" -- "$lpid"
			stopped
		done
		for sig in TERM KILL; do
			start_upgrade "$mode"
			kill "-$sig" -- "-$lpid"
			stopped
		done
	done
}

@test "FR50, NFR5: KILL between staging and the rename removes the staged file and keeps lendk" {
	local i staged=''
	base "$REL/new"
	set -m
	LENDK_TEST_PAUSE=9 LENDK_TIMEOUT=30 LENDK_TEST_FAMILY=$SENTINEL "$LENDK" upgrade </dev/null >"$SB/stdout" 2>"$SB/stderr" &
	lpid=$!
	set +m
	# The job sets the staged file's mode last, then lendk waits in LENDK_TEST_PAUSE.
	for ((i = 0; i < 100; i++)); do
		staged=$(compgen -G "$BIN/.lendk.*") && [[ -x $staged ]] && break
		sleep 0.1
	done
	cmp "$staged" "$REL/new.src/lendk-99.0.0/bin/lendk"
	sleep 0.5
	[[ -n $(ls -A "$TMPDIR") ]]
	assert_eq "$(cksum <"$LENDK")" "$SUM"
	kill -KILL -- "$lpid"
	stopped
}

@test "AC7: install.sh, then upgrade, against make dist releases" {
	require git
	require make
	local d src=$SB/src sys=$SB/sys before
	# sums: the bytes AC7 says upgrade leaves alone.
	sums() {
		find "$HOME/.profile" "$MAP" "$SB/store" "$SB/skills" -type f | LC_ALL=C sort | while IFS= read -r d; do cksum "$d"; done
	}
	mkdir -p "$src" "$sys"
	local IFS=:
	for d in $PATH; do
		[[ -d $d && $d != "$SB/bin" ]] && find "$d" -maxdepth 1 \( -type f -o -type l \) -perm -u+x -exec ln -s {} "$sys/" \; 2>/dev/null
	done
	unset IFS
	(cd "$sys" && rm -f bash pass gpg gpg2 curl wget apt-get dnf pacman zypper apk brew systemctl sudo)
	ln -s "$BASH" "$SB/bin/bash"
	printf '#!/bin/sh\necho "gpg (GnuPG) 2.4.5"\n' >"$SB/bin/gpg" && chmod +x "$SB/bin/gpg"
	ln -s "$FIXTURES/stub-target" "$SB/bin/gh"
	cp -R "$ROOT/bin" "$ROOT/skills" "$ROOT/Makefile" "$ROOT/LICENSE" "$ROOT/install.sh" "$src/"
	git -C "$src" init -q
	for d in r1 r2; do
		[[ $d == r1 ]] || sed 's/^LENDK_VERSION=.*/LENDK_VERSION=99.0.0/' "$ROOT/bin/lendk" >"$src/bin/lendk"
		git -C "$src" add -A
		git -C "$src" -c user.name=test -c user.email=test commit -qm "$d"
		make -s -C "$src" dist >/dev/null
		mkdir -p "$SB/$d/latest/download"
		cp "$src"/dist/* "$SB/$d/latest/download/"
	done
	rm "$LENDK"
	run env -i HOME="$HOME" PATH="$SB/bin:$sys" SHELL=/bin/bash TMPDIR="$TMPDIR" PASSWORD_STORE_DIR="$PASSWORD_STORE_DIR" \
		LENDK_INSTALL_BASE_URL="file://$SB/r1" sh "$ROOT/install.sh" --skill-dir "$SB/skills"
	assert_eq "${lines[-1]}" "lendk-install: ok: lendk $VERSION installed to $LENDK"
	cmp "$LENDK" "$ROOT/bin/lendk"
	[[ -f $SB/skills/lendk/SKILL.md ]]
	grep -qx '# >>> lendk-install >>>' "$HOME/.profile"
	export PATH=$SHIMS:$SB/bin:$sys
	printf '%s\n' "$SENTINEL" >"$SB/store/env/GH_TOKEN.gpg"
	LENDK_PROMPT=allow run_lendk add gh GH_TOKEN
	assert_eq "$status" 0
	mark
	before=$(sums)
	base "$SB/r2"
	run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$output" "upgraded lendk $VERSION to 99.0.0 at $LENDK"
	cmp "$LENDK" "$src/bin/lendk"
	assert_eq "$(sums)" "$before"
	run_lendk check gh
	assert_eq "$status" 0
	assert_line "$output" $'gh\tGH_TOKEN\tok'
	gh >/dev/null
	local logs=("$SB"/log/target.*)
	tr '\0' '\n' <"${logs[0]}/env" | grep -qx "GH_TOKEN=$SENTINEL"
	mark
	run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$output" "lendk 99.0.0 is up to date: the latest release is 99.0.0"
	unchanged
	assert_eq "$(sums)" "$before"
}

@test "FR50: TERM, INT or HUP before the watchdog starts removes both files and is re-raised" {
	local sig i rc
	base "$REL/new"
	for sig in TERM INT HUP; do
		set -m
		LENDK_TEST_PAUSE=9 LENDK_TEST_AT=start LENDK_TEST_FAMILY=$SENTINEL "$LENDK" upgrade </dev/null >"$SB/stdout" 2>"$SB/stderr" &
		lpid=$!
		set +m
		for ((i = 0; i < 50; i++)); do
			[[ -n $(ls -A "$TMPDIR") && -n $(compgen -G "$BIN/.lendk.*") ]] && break
			sleep 0.1
		done
		[[ -n $(ls -A "$TMPDIR") && -n $(compgen -G "$BIN/.lendk.*") ]]
		sleep 0.3
		# Only lendk runs: no watchdog could remove the files.
		assert_eq "$(family)" "$lpid"
		kill "-$sig" -- "$lpid"
		rc=0
		wait "$lpid" || rc=$?
		assert_eq "$rc" "$((128 + $(kill -l "$sig")))"
		stopped
	done
}

@test "FR50: TERM, INT, HUP or KILL after an expiry, while the watchdog stops a tool that ignores TERM, leaves nothing" {
	local sig i err
	for sig in TERM INT HUP KILL; do
		rm -rf "$SB/log"/*
		web new stubborn
		set -m
		LENDK_TIMEOUT=1 LENDK_TEST_FAMILY=$SENTINEL "$LENDK" upgrade </dev/null >"$SB/stdout" 2>"$SB/stderr" &
		lpid=$!
		set +m
		for ((i = 0; i < 500; i++)); do
			[[ -z $(compgen -G "$TMPDIR/lendk.*/timeout") ]] || break
			! gone "$lpid" || break
			sleep 0.01
		done
		kill "-$sig" -- "$lpid" 2>/dev/null || true
		none_within 2
		wait "$lpid" 2>/dev/null || true
		unchanged
		assert_eq "$(<"$SB/stdout")" ""
		# A signal that came after lendk's own exit finds the expiry line already printed.
		err=$(<"$SB/stderr")
		[[ $err == "$NOTICE" || $err == "$NOTICE"$'\n'"lendk: upgrade: fetching the release did not finish within 1 s. Stop and ask the user." ]]
	done
}

@test "FR50, NFR5: when the watchdog dies, its rescue removes the staged file of a killed lendk" {
	local i p staged='' inner=''
	base "$REL/new"
	set -m
	LENDK_TEST_PAUSE=9 LENDK_TIMEOUT=30 LENDK_TEST_FAMILY=$SENTINEL "$LENDK" upgrade </dev/null >"$SB/stdout" 2>"$SB/stderr" &
	lpid=$!
	set +m
	for ((i = 0; i < 100; i++)); do
		staged=$(compgen -G "$BIN/.lendk.*") && [[ -x $staged ]] && break
		sleep 0.1
	done
	[[ -x $staged ]]
	sleep 0.5
	# lendk waits before the rename; its children are the watchdog's shell and, inside it, the watchdog.
	for p in $(family); do
		[[ $p == "$lpid" || $(ppid_of "$p") == "$lpid" ]] || inner=$p
	done
	[[ -n $inner ]]
	kill -KILL -- "$inner"
	kill -KILL -- "$lpid"
	stopped
}
