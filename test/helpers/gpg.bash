# Real GnuPG helpers, loaded after common.bash and sandbox: a scratch GnuPG home under /tmp, short enough for the agent's socket path, whose
# agent asks pinentry-recorder, a passphrase-protected key and a store initialized for it.
# shellcheck disable=SC2034
GPG_PASS=lend-test-passphrase

# gpg_guard: HOME is the sandbox's and GNUPGHOME a scratch home, so no helper reaches a real keyring.
gpg_guard() {
	[[ -n ${BATS_TEST_TMPDIR-} && ${HOME-} == "$BATS_TEST_TMPDIR/home" ]] ||
		{ echo "gpg.bash: HOME '${HOME-}' is outside the sandbox" >&2; return 1; }
	[[ ${GNUPGHOME-} == /tmp/lend-gpg.?* && ${GNUPGHOME#/tmp/lend-gpg.} != */* && -d $GNUPGHOME && -O $GNUPGHOME ]] ||
		{ echo "gpg.bash: GNUPGHOME '${GNUPGHOME-}' is outside the sandbox" >&2; return 1; }
}

# gpg_setup: the scratch home, key and store; KEYID names the key. The agent starts with an empty cache.
gpg_setup() {
	rm -f "$SB/bin/pass"
	require gpg
	require pass
	[[ ${HOME-} == "${BATS_TEST_TMPDIR-}/home" ]] || { gpg_guard; return 1; }
	GNUPGHOME=$(mktemp -d /tmp/lend-gpg.XXXXXX) || return 1
	export GNUPGHOME
	gpg_guard || return 1
	printf '#!/bin/sh\nexec %q %q\n' "$FIXTURES/pinentry-recorder" "$GNUPGHOME" >"$GNUPGHOME/pinentry"
	chmod 700 "$GNUPGHOME/pinentry"
	printf '%s\n' "$GPG_PASS" >"$GNUPGHOME/pinentry.pass"
	printf 'pinentry-program %s\nallow-loopback-pinentry\n' "$GNUPGHOME/pinentry" >"$GNUPGHOME/gpg-agent.conf"
	gpg --batch --quiet --pinentry-mode loopback --passphrase "$GPG_PASS" \
		--quick-gen-key 'lend test key' future-default default never 2>/dev/null || return 1
	KEYID=$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
	[[ -n $KEYID ]] || return 1
	pass init "$KEYID" >/dev/null 2>&1 || return 1
	gpg_cold
}

# gpg_insert KEY VALUE: an encrypted store entry.
gpg_insert() {
	printf '%s\n' "$2" | pass insert -m "env/$1" >/dev/null
}

# gpg_cold: flush the agent's cached passphrases and the recorder's logs.
gpg_cold() {
	gpg_guard || return 1
	gpgconf --reload gpg-agent
	rm -f "$GNUPGHOME"/pinentry.{pids,options,mode}
}

# gpg_prime: cache the passphrase through a loopback decrypt.
gpg_prime() {
	gpg_guard || return 1
	gpg --batch --quiet --pinentry-mode loopback --passphrase "$GPG_PASS" -d "$PASSWORD_STORE_DIR/env/$1.gpg" >/dev/null
}

# with_gpg2 / without_gpg2: put a gpg2 symlink first on PATH, which moves pass to its --batch branch,
# or take it away; without_gpg2 skips when the system has its own gpg2.
with_gpg2() { ln -sf "$(type -P gpg)" "$SB/bin/gpg2"; }
without_gpg2() {
	rm -f "$SB/bin/gpg2"
	! type -P gpg2 >/dev/null || skip "the system provides gpg2"
}

# gone_within SECONDS PID...: every PID is gone within SECONDS.
gone_within() {
	local i p left
	for ((i = 0; i <= $1 * 10; i++)); do
		left=
		for p in "${@:2}"; do gone "$p" || left+=" $p"; done
		[[ -z $left ]] && return 0
		sleep 0.1
	done
	echo "still running:$left" >&2
	return 1
}

# gpg_teardown: stop the scratch agent and remove its home.
gpg_teardown() {
	[[ ${GNUPGHOME-} == /tmp/lend-gpg.?* ]] || return 0
	gpg_guard || return 0
	gpgconf --kill gpg-agent
	gpgconf --remove-socketdir 2>/dev/null
	rm -rf "$GNUPGHOME"
}
