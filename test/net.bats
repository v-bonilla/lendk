#!/usr/bin/env bats
# NFR6: no network. Every verb runs under strace watching connect; the source names no network tool.

setup() {
	load helpers/common
	sandbox
	MAP=$HOME/.config/lend/map
	mkdir -p "$HOME/.config/lend" && chmod 700 "$HOME/.config/lend"
	printf 'stub K1\n' >"$MAP"
	chmod 600 "$MAP"
	ln -s "$FIXTURES/stub-target" "$SB/bin/stub"
	ln -s "$FIXTURES/stub-target" "$SB/bin/other"
	printf '%s\n' "$SENTINEL" >"$SB/store/env/K1.gpg"
}

teardown() {
	load helpers/gpg
	gpg_teardown
}

# traced ARG...: lend ARG... under strace; then no AF_INET or AF_INET6 connect is in the trace.
traced() {
	strace -f --seccomp-bpf -e trace=connect -o "$SB/trace" "$LEND" "$@" </dev/null >/dev/null 2>&1 || :
	[[ -s $SB/trace ]] || { echo "strace wrote no trace" >&2; return 1; }
	! grep -E 'AF_INET6?[,}]' "$SB/trace"
}

@test "NFR6: no verb connects to an internet address" {
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
}

# bats test_tags=gpg
@test "NFR6: run and unlock with real GnuPG connect to no internet address" {
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

@test "NFR6: the source names no curl, wget, nc or /dev/tcp" {
	run grep -nE '(^|[^A-Za-z0-9_-])(curl|wget|nc)([^A-Za-z0-9_-]|$)|/dev/(tcp|udp)' "$LEND"
	assert_eq "$output" ""
}
