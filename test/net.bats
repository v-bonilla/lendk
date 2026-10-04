#!/usr/bin/env bats
# NFR6: no network outside upgrade's download tool. Every verb runs under strace watching connect; the
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
	printf '%s\n' "$SENTINEL" >"$SB/store/env/K1.gpg"
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
	mkdir -p "$HOME/.local/bin"
	cp "$LENDK" "$HOME/.local/bin/lendk"
	LENDK=$HOME/.local/bin/lendk
	release "$SB/rel" 99.0.0
	LENDK_INSTALL_BASE_URL=file://$SB/rel traced upgrade
	assert_eq "$("$LENDK" --version)" "lendk 99.0.0"
	[[ ! -e $SB/log/net ]]
}

@test "NFR6: no verb starts a download tool, upgrade from a file:// base included" {
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

@test "NFR6: the source names curl and wget only in the network region, and no nc or /dev/tcp" {
	assert_eq "$(grep -c '^# lint: network begin$' "$LENDK")" 1
	assert_eq "$(grep -c '^# lint: network end$' "$LENDK")" 1
	[[ $(sed -n '/^# lint: network begin$/,/^# lint: network end$/p' "$LENDK" | grep -cE 'curl|wget') -gt 0 ]]
	run grep -nE '(^|[^A-Za-z0-9_-])(curl|wget|nc)([^A-Za-z0-9_-]|$)|/dev/(tcp|udp)' <(sed '/^# lint: network begin$/,/^# lint: network end$/d' "$LENDK")
	assert_eq "$output" ""
	run grep -nE '(^|[^A-Za-z0-9_-])nc([^A-Za-z0-9_-]|$)|/dev/(tcp|udp)' "$LENDK"
	assert_eq "$output" ""
	# The region is comment lines and one function, with no command of its own.
	local region
	region=$(sed -n '/^# lint: network begin$/,/^# lint: network end$/p' "$LENDK" | sed '1d;$d' | grep -v '^#')
	assert_eq "$(sed -n 1p <<<"$region")" 'upgrade_download() {'
	assert_eq "$(tail -n 1 <<<"$region")" '}'
	assert_eq "$(grep -v "^$(printf '\t')" <<<"$region")" $'upgrade_download() {\n}'
	# Only upgrade's own functions call it.
	run awk '
		/^[a-z_]+\(\) \{$/ { f = $1 }
		/^\}$/ { f = "top level" }
		/upgrade_download/ && !/^#/ && !/^upgrade_download\(\) \{$/ { print f }' "$LENDK"
	assert_eq "$(sort -u <<<"$output")" $'upgrade_fetch()\nupgrade_verb()'
}
