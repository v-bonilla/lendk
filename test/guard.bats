#!/usr/bin/env bats
# FR22: the opening lines of bin/lend reject bash older than 4.4.

setup() {
	load helpers/common
	sandbox
}

# old_bash IMAGE [DOCKER-ARG...]: run lend --version in IMAGE, stderr captured.
old_bash() {
	local image=$1
	shift
	status=0
	stderr=$(docker run --rm "$@" -v "$LEND:/lend:ro" "$image" bash /lend --version 2>&1 </dev/null) || status=$?
}

# bats test_tags=docker
@test "FR22: bash 3.2 gives unsupported with exit 125" {
	require docker
	old_bash bash:3.2.57
	assert_eq "$stderr" "lend: unsupported: bash 3.2.57 found; lend needs bash 4.4 or later. Stop and ask the user."
	assert_class unsupported 125
}

# bats test_tags=docker
@test "FR22: bash 4.3 gives unsupported with exit 125, and the interactive FIX when prompting is allowed" {
	require docker
	old_bash bash:4.3.48
	assert_eq "$stderr" "lend: unsupported: bash 4.3.48 found; lend needs bash 4.4 or later. Stop and ask the user."
	assert_class unsupported 125
	old_bash bash:4.3.48 -e LEND_PROMPT=allow
	assert_eq "$stderr" "lend: unsupported: bash 4.3.48 found; lend needs bash 4.4 or later. Put a newer bash first on PATH."
	assert_class unsupported 125
}

@test "FR22: the current bash passes the guard" {
	run_lend --version
	assert_eq "$status" 0
	[[ $output == "lend "[0-9]*.[0-9]*.[0-9]* ]]
	assert_eq "$stderr" ""
}
