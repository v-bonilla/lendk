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
	stderr=$(docker run --rm --pull never "$@" -v "$LEND:/lend:ro" "$image" bash /lend --version 2>&1 </dev/null) || status=$?
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

# stub_gpg NAME VERSION: a NAME on PATH reporting GnuPG VERSION.
stub_gpg() {
	printf '#!/bin/sh\necho "gpg (GnuPG) %s"\necho "libgcrypt 1.8.0"\n' "$2" >"$SB/bin/$1"
	chmod +x "$SB/bin/$1"
}

# gpg2_follows: a gpg2 first on PATH that runs the stub gpg, so a system gpg2, which lend prefers, is out of play.
gpg2_follows() {
	printf '#!/bin/sh\nexec %q "$@"\n' "$SB/bin/gpg" >"$SB/bin/gpg2"
	chmod +x "$SB/bin/gpg2"
}

@test "FR22: run and unlock give unsupported for a gpg below 2.4, before any decrypt" {
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	mkdir -p "$HOME/.config/lend" && chmod 700 "$HOME/.config/lend"
	printf 'stub K1\n' >"$HOME/.config/lend/map"
	chmod 600 "$HOME/.config/lend/map"
	printf 'value\n' >"$SB/store/env/K1.gpg"
	stub_gpg gpg 2.2.27
	gpg2_follows
	run_lend run -- stub
	assert_eq "$stderr" "lend: unsupported: GnuPG 2.2.27 found; lend needs GnuPG 2.4 or later. Stop and ask the user."
	assert_class unsupported 125
	LEND_PROMPT=allow run_lend unlock K1
	assert_eq "$stderr" "lend: unsupported: GnuPG 2.2.27 found; lend needs GnuPG 2.4 or later. Upgrade GnuPG."
	assert_eq "$(compgen -G "$SB/log/pass.*")" ""
	assert_eq "$(compgen -G "$SB/log/target.*")" ""
	K1=preset run_lend run -- stub
	assert_eq "$status" 0
	stub_gpg gpg 2.4.0
	stub_gpg gpg2 2.2.27
	run_lend unlock K1
	assert_class unsupported 125
	stub_gpg gpg2 2.4.4
	run_lend unlock K1
	assert_eq "$output" unlocked
}

@test "FR22: the GnuPG version parses strictly, and gpg --version runs under the allowlisted environment" {
	local v
	mkdir -p "$HOME/.config/lend" && chmod 700 "$HOME/.config/lend"
	printf 'value\n' >"$SB/store/env/K1.gpg"
	gpg2_follows
	for v in 2.4.0 2.10.1 2.4.0-beta 2.5.12; do
		stub_gpg gpg "$v"
		run_lend unlock K1
		assert_eq "$output" unlocked
	done
	for v in '2.2.27 ' 2.3.8 1.4.23 2.4 x.y.z ''; do
		stub_gpg gpg "$v"
		run_lend unlock K1
		assert_class unsupported 125
		[[ $stderr == "lend: unsupported: GnuPG "*" found; lend needs GnuPG 2.4 or later. Stop and ask the user." ]]
	done
	printf '#!/bin/sh\necho "gpg (GnuPG/MacGPG2) 2.2.41"\n' >"$SB/bin/gpg"
	run_lend unlock K1
	assert_eq "$stderr" "lend: unsupported: GnuPG 2.2.41 found; lend needs GnuPG 2.4 or later. Stop and ask the user."
	printf '#!/bin/sh\nenv >"%s"\necho "gpg (GnuPG) 2.4.7"\n' "$SB/log/gpg-env" >"$SB/bin/gpg"
	SECRET_X=$SENTINEL run_lend unlock K1
	assert_eq "$output" unlocked
	refute_contains "$(<"$SB/log/gpg-env")" "$SENTINEL"
	assert_line "$(<"$SB/log/gpg-env")" "HOME=$HOME"
}

@test "FR22: gpg.bash aborts when HOME or GNUPGHOME lies outside the sandbox" {
	load helpers/gpg
	printf '#!/bin/sh\necho called >>"%s"\n' "$SB/log/gpg-calls" >"$SB/bin/gpg"
	printf '#!/bin/sh\necho called >>"%s"\n' "$SB/log/gpg-calls" >"$SB/bin/gpgconf"
	chmod +x "$SB/bin/gpg" "$SB/bin/gpgconf"
	HOME=/home/alice run gpg_setup
	assert_eq "$status" 1
	assert_line "$output" "gpg.bash: HOME '/home/alice' is outside the sandbox"
	GNUPGHOME=/home/alice/.gnupg run gpg_guard
	assert_eq "$status" 1
	assert_line "$output" "gpg.bash: GNUPGHOME '/home/alice/.gnupg' is outside the sandbox"
	GNUPGHOME=/home/alice/.gnupg run gpg_cold
	assert_eq "$status" 1
	GNUPGHOME=/tmp/lend-gpg.x/../../home/alice run gpg_guard
	assert_eq "$status" 1
	assert_eq "$(compgen -G "$SB/log/gpg-calls")" ""
}
