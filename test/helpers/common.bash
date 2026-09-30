# Shared test helpers; every test file loads this and calls sandbox from setup.
# shellcheck disable=SC2034,SC2016
ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
LEND=$ROOT/bin/lend
FIXTURES=$ROOT/test/fixtures
CLASSES='usage|guarded|unsupported|locked|canceled|timeout|map|unmapped|missing-key|decrypt|unsafe|write|exec|not-found|lend-missing'
FORBIDDEN='lend add|lend rm|lend run [A-Z@]|pass |printenv|env -0|export -p|npm|cargo|pip install|brew'
sandbox() {
	local name
	for name in $(compgen -e); do
		[[ $name =~ ^(BATS|PATH$|TERM$|LANG$|LC_|USER$|LOGNAME$|SHELL$|PWD$|SHLVL$|TZ$|TEST_REQUIRE$) ]] || unset "$name"
	done
	SB=$BATS_TEST_TMPDIR
	mkdir -p "$SB/home" "$SB/tmp" "$SB/store/env" "$SB/log" "$SB/bin"
	ln -s "$FIXTURES/fake-pass" "$SB/bin/pass"
	export HOME=$SB/home TMPDIR=$SB/tmp PASSWORD_STORE_DIR=$SB/store PATH=$SB/bin:$PATH STUB_LOG=$SB/log
	SENTINEL=lend-sentinel-$RANDOM$RANDOM$RANDOM
	# lend-fn FUNCTION ARG...: call one of lend's functions, the file's definitions loaded.
	printf '#!/usr/bin/env bash\nsource <(sed %q %q)\n"$@"\n' '$d' "$LEND" >"$SB/bin/lend-fn"
	chmod +x "$SB/bin/lend-fn"
}

# run_lend ARG...: status, output (stdout), stderr; every stderr line must follow PRD 5.3.
run_lend() {
	local line
	status=0
	output=$("$LEND" "$@" </dev/null 2>"$SB/stderr") || status=$?
	stderr=$(<"$SB/stderr")
	while IFS= read -r line; do
		[[ $line =~ ^lend:\ ($CLASSES):\ .+\.\ .+$ || $line =~ ^lend:\ notice:\ .+\.$ ]] ||
			{ echo "stderr line breaks the contract: $line" >&2; return 1; }
		[[ ${LEND_PROMPT-} == allow || ! $line =~ $FORBIDDEN ]] ||
			{ echo "non-interactive line suggests a forbidden action: $line" >&2; return 1; }
	done <"$SB/stderr"
}
assert_eq() { [[ $1 == "$2" ]] || { printf 'expected: %q\nactual:   %q\n' "$2" "$1" >&2; return 1; }; }
assert_line() { [[ $'\n'$1$'\n' == *$'\n'"$2"$'\n'* ]] || { printf 'no line %q in:\n%s\n' "$2" "$1" >&2; return 1; }; }
refute_contains() { [[ $1 != *"$2"* ]] || { printf 'unexpected %q in:\n%s\n' "$2" "$1" >&2; return 1; }; }
# assert_class CLASS STATUS: stderr ends with one line of CLASS, and lend exited STATUS.
assert_class() {
	[[ ${stderr##*$'\n'} == "lend: $1: "* ]] || { printf 'expected class %s, stderr:\n%s\n' "$1" "$stderr" >&2; return 1; }
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
# gone PID: the process is absent or a zombie.
gone() {
	local stat
	read -r stat 2>/dev/null <"/proc/$1/stat" || return 0
	stat=${stat##*) }
	[[ ${stat%% *} == Z ]]
}
# family: live PIDs of lend's processes, which inherit LEND_TEST_FAMILY=$SENTINEL, and of the fake
# pass calls and their children, which the fake records in $SB/log/pids.
family() {
	local p f
	while IFS= read -r f; do
		p=${f#/proc/}
		p=${p%/environ}
		gone "$p" || printf '%s\n' "$p"
	done < <(grep -lF "LEND_TEST_FAMILY=$SENTINEL" /proc/[0-9]*/environ 2>/dev/null)
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
