#!/usr/bin/env bats
# No network outside upgrade's download tool. Every verb runs under strace watching connect; the
# source names the download tools only in its network region.
# shellcheck disable=SC2030,SC2031

setup() {
	load helpers/common
	sandbox
	MAP=$HOME/.config/lendk/map
	mkdir -p "$HOME/.config/lendk" && chmod 700 "$HOME/.config/lendk"
	printf 'stub K1\n' >"$MAP"
	chmod 600 "$MAP"
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	ln -s "$FIXTURES/stub-target" "$SB/bin/other"
	store_entry K1 "$SENTINEL"
}

teardown() {
	load helpers/gpg
	gpg_teardown
}

# traced ARG...: lendk ARG... under strace; then no AF_INET or AF_INET6 connect is in the trace.
traced() {
	strace -f --seccomp-bpf -e trace=connect -o "$SB/trace" "$LENDK" "$@" </dev/null >/dev/null 2>&1 || :
	[[ -s $SB/trace ]] || { echo "strace wrote no trace" >&2; return 1; }
	! grep -E 'AF_INET6?[,}]' "$SB/trace"
}

@test "no verb connects to an internet address" {
	require strace
	traced --help
	traced --version
	traced init sh
	traced check
	traced sync
	traced add other K1
	traced rm other
	traced run -- stub
	traced run K1 -- stub
	traced unlock K1
	targets=("$SB"/log/target.*)
	assert_eq "${#targets[@]}" 2
	mkdir -p "$HOME/.local/bin"
	cp "$LENDK" "$HOME/.local/bin/lendk"
	LENDK=$HOME/.local/bin/lendk
	release "$SB/rel" 99.0.0
	LENDK_INSTALL_BASE_URL=file://$SB/rel traced upgrade
	assert_eq "$("$LENDK" --version)" "lendk 99.0.0"
	[[ ! -e $SB/log/net ]]
}

@test "no verb starts a download tool, upgrade from a file:// base included" {
	local verb
	for verb in --help --version "init sh" check sync "add other K1" "rm other" "run -- stub" "run K1 -- stub" "unlock K1" frobnicate; do
		# shellcheck disable=SC2086
		"$LENDK" $verb </dev/null >/dev/null 2>&1 || :
	done
	mkdir -p "$HOME/.local/bin"
	cp "$LENDK" "$HOME/.local/bin/lendk"
	release "$SB/rel" 99.0.0
	LENDK=$HOME/.local/bin/lendk LENDK_INSTALL_BASE_URL=file://$SB/rel run_lendk upgrade
	assert_eq "$status" 0
	assert_eq "$("$HOME/.local/bin/lendk" --version)" "lendk 99.0.0"
	[[ ! -e $SB/log/net ]]
	curl https://example.org || :
	[[ -s $SB/log/net ]]
}

# bats test_tags=gpg
@test "run and unlock with real GnuPG connect to no internet address" {
	require strace
	load helpers/gpg
	gpg_setup
	gpg_insert K1 "$SENTINEL"
	gpg_prime K1
	traced run -- stub
	traced unlock K1
	targets=("$SB"/log/target.*)
	assert_eq "${#targets[@]}" 1
}
