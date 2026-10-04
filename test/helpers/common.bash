# Shared test helpers; every test file loads this and calls sandbox from setup.
# shellcheck disable=SC2034,SC2016
ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
LENDK=$ROOT/bin/lendk
FIXTURES=$ROOT/test/fixtures
CLASSES='usage|guarded|unsupported|locked|canceled|timeout|map|unmapped|missing-key|decrypt|unsafe|write|upgrade|exec|not-found|lendk-missing'
FORBIDDEN='lendk add|lendk rm|lendk run [A-Z@]|lendk upgrade|pass |printenv|env -0|export -p|npm|cargo|pip install|brew'
sandbox() {
	local name
	for name in $(compgen -e); do
		[[ $name =~ ^(BATS|PATH$|TERM$|LANG$|LC_|USER$|LOGNAME$|SHELL$|PWD$|SHLVL$|TZ$|TEST_REQUIRE$) ]] || unset "$name"
	done
	SB=$BATS_TEST_TMPDIR
	mkdir -p "$SB/home" "$SB/tmp" "$SB/store/env" "$SB/log" "$SB/bin"
	ln -s "$FIXTURES/fake-pass" "$SB/bin/pass"
	# No test reaches the network: the download tools fail, and record each call in $SB/log/net,
	# unless a test replaces them.
	for name in curl wget; do
		printf '#!/bin/sh\necho "%s $*" >>%q\nexit 7\n' "$name" "$SB/log/net" >"$SB/bin/$name"
		chmod +x "$SB/bin/$name"
	done
	export HOME=$SB/home TMPDIR=$SB/tmp PASSWORD_STORE_DIR=$SB/store PATH=$SB/bin:$PATH STUB_LOG=$SB/log
	SENTINEL=lendk-sentinel-$RANDOM$RANDOM$RANDOM
	# lendk-fn FUNCTION ARG...: call one of lendk's functions, the file's definitions loaded.
	printf '#!/usr/bin/env bash\nsource <(sed %q %q)\n"$@"\n' '$d' "$LENDK" >"$SB/bin/lendk-fn"
	chmod +x "$SB/bin/lendk-fn"
}

# run_lendk ARG...: status, output (stdout), stderr; every stderr line must follow PRD 5.3, and the
# sandbox's download stubs must stay unused.
run_lendk() {
	local line
	# upgrade replaces the file it runs from, so it only ever runs on a copy.
	[[ ${1-} != upgrade || ! $LENDK -ef $ROOT/bin/lendk ]] ||
		{ echo "run_lendk refuses upgrade on the working tree's bin/lendk" >&2; return 1; }
	status=0
	output=$("$LENDK" "$@" </dev/null 2>"$SB/stderr") || status=$?
	stderr=$(<"$SB/stderr")
	while IFS= read -r line; do
		[[ $line =~ ^lendk:\ ($CLASSES):\ .+\.\ .+$ || $line =~ ^lendk:\ notice:\ .+\.$ ]] ||
			{ echo "stderr line breaks the contract: $line" >&2; return 1; }
		[[ ${LENDK_PROMPT-} == allow || ! $line =~ $FORBIDDEN ]] ||
			{ echo "non-interactive line suggests a forbidden action: $line" >&2; return 1; }
	done <"$SB/stderr"
	# NFR6: the sandbox's download stubs record their calls, and no call of the suite may start one.
	[[ ! -e $SB/log/net ]] || { echo "lendk started a download tool: $(<"$SB/log/net")" >&2; return 1; }
}
assert_eq() { [[ $1 == "$2" ]] || { printf 'expected: %q\nactual:   %q\n' "$2" "$1" >&2; return 1; }; }
assert_line() { [[ $'\n'$1$'\n' == *$'\n'"$2"$'\n'* ]] || { printf 'no line %q in:\n%s\n' "$2" "$1" >&2; return 1; }; }
refute_contains() { [[ $1 != *"$2"* ]] || { printf 'unexpected %q in:\n%s\n' "$2" "$1" >&2; return 1; }; }
# assert_class CLASS STATUS: stderr ends with one line of CLASS, and lendk exited STATUS.
assert_class() {
	[[ ${stderr##*$'\n'} == "lendk: $1: "* ]] || { printf 'expected class %s, stderr:\n%s\n' "$1" "$stderr" >&2; return 1; }
	assert_eq "$status" "$2"
}
# require TOOL: skip when absent, fail when TEST_REQUIRE lists it.
require() {
	case $1 in
	environment-d) [[ -x /usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator ]] && return 0 ;;
	*) command -v "$1" >/dev/null && return 0 ;;
	esac
	[[ " ${TEST_REQUIRE-} " != *" $1 "* ]] || { echo "required tool missing: $1" >&2; return 1; }
	skip "$1 not available"
}
# skel_profile: the fixture login profile. On macOS, /etc/profile puts /usr/bin and its bash 3.2
# first, so the profile starts by putting this bash first, as eval "$(brew shellenv)" does.
skel_profile() {
	[[ $(uname -s) != Darwin ]] || printf 'PATH=%s:$PATH\n' "${BASH%/*}"
	cat "$FIXTURES/profile"
}
# BSD wc pads its counts with spaces; GNU wc reading stdin does not.
wc() { command wc "$@" | sed 's/^ *//'; }
# timeout SECONDS CMD...: GNU timeout, or perl's alarm where coreutils lacks it (macOS).
command -v timeout >/dev/null || timeout() { perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }
# now_ms: milliseconds since the epoch.
now_ms() {
	if [[ -n ${EPOCHREALTIME-} ]]; then
		local t=${EPOCHREALTIME/,/.}
		printf '%s\n' "$((${t%.*} * 1000 + 10#${t#*.} / 1000))"
	else
		date +%s%3N
	fi
}
# gone PID: the process is absent or a zombie.
gone() {
	local stat
	if [[ -d /proc/self ]]; then
		read -r stat 2>/dev/null <"/proc/$1/stat" || return 0
		stat=${stat##*) }
	else
		stat=$(ps -o stat= -p "$1" 2>/dev/null) || return 0
		stat=${stat//[[:space:]]/}
	fi
	[[ ${stat%% *} == Z* ]]
}
# family: live PIDs of lendk's processes, which inherit LENDK_TEST_FAMILY=$SENTINEL, and of the fake
# pass calls and their children, which the fake records in $SB/log/pids.
family() {
	local p f
	if [[ -d /proc/self ]]; then
		while IFS= read -r f; do
			p=${f#/proc/}
			p=${p%/environ}
			gone "$p" || printf '%s\n' "$p"
		done < <(grep -lF "LENDK_TEST_FAMILY=$SENTINEL" /proc/[0-9]*/environ 2>/dev/null)
	else
		# BSD ps -E appends each process's environment to its command.
		while read -r p f; do
			[[ $f != *"LENDK_TEST_FAMILY=$SENTINEL"* ]] || gone "$p" || printf '%s\n' "$p"
		done < <(ps -A -E -ww -o pid= -o command= 2>/dev/null)
	fi
	[[ -f $SB/log/pids ]] || return 0
	while read -r p; do gone "$p" || printf '%s\n' "$p"; done <"$SB/log/pids"
}
# none_within SECONDS: family is empty within SECONDS.
none_within() {
	local i left
	for ((i = 0; i <= $1 * 10; i++)); do
		left=$(family)
		[[ -z $left ]] && return 0
		sleep 0.1
	done
	echo "still running: $left" >&2
	return 1
}
# snapshot: every path under the sandbox except the logs, with its listing and checksum.
snapshot() {
	local p sum
	while IFS= read -r p; do
		sum=
		[[ -f $p && ! -L $p ]] && sum=$(cksum <"$p")
		printf '%s %s %s\n' "$p" "$(command ls -ldn "$p" | awk '{ print $1, $2, $3, $4, $5 }')" "$sum"
	done < <(find "$SB" \( -path "$SB/log" -o -path "$SB/stderr" \) -prune -o -print | sort)
}
# timed_lendk ARG...: run_lendk ARG..., with its wall time in seconds in elapsed.
timed_lendk() {
	local TIMEFORMAT=%R
	{ time run_lendk "$@"; } 2>"$SB/time"
	elapsed=$(<"$SB/time")
}
# within LOW HIGH: LOW <= elapsed < HIGH, in whole and tenth seconds.
within() {
	local t=${elapsed/./}
	t=$((10#${t:0:${#t}-2}))
	((t >= $1 * 10 && t < $2 * 10)) || { echo "took $elapsed s, expected [$1, $2)" >&2; return 1; }
}
# sha256 FILE: its SHA-256 line, as sha256sum prints it.
sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}
# pack SRC DIR: a release in make dist's layout under DIR, from the lendk-X.Y.Z tree in SRC.
pack() {
	mkdir -p "$2/latest/download"
	(cd "$1" && tar -cf - lendk-*) | gzip >"$2/latest/download/lendk.tar.gz"
	(cd "$2/latest/download" && sha256 lendk.tar.gz >SHA256SUMS)
}
# release DIR VERSION: pack the working tree's lendk as VERSION, with LICENSE and skills, under DIR.
release() {
	local src=$1.src/lendk-$2
	mkdir -p "$src/bin"
	sed "s/^LENDK_VERSION=.*/LENDK_VERSION=$2/" "$ROOT/bin/lendk" >"$src/bin/lendk"
	chmod 755 "$src/bin/lendk"
	cp "$ROOT/LICENSE" "$src/"
	cp -R "$ROOT/skills" "$src/"
	pack "$1.src" "$1"
}
