#!/bin/bash
# PROTOTYPE for lendk #34, throwaway, never merged: walks a human through #34's claims on a throwaway macOS account and logs every result.
# Usage: ./probe.sh build|gui|ssh|ssh-again|settings|cleanup by hand, ./probe.sh ci on a CI runner; README.md gives the order.
# With PROBE_CI set nobody answers: questions are logged, and a call still waiting after 8 s gets a screenshot and a dump of the windows on screen.
set -u

here=$(cd "$(dirname "$0")" && pwd)
builds=$here/builds
# Release N and N+1 replace each other at this one path, as `lendk upgrade` replaces lendk.
install_dir=$HOME/.local/keychain-probe
probe_bin=$install_dir/keychain-probe
login_kc=$HOME/Library/Keychains/login.keychain-db
account=age1prototype34keychaincacheprobe
phase=${1-}

die() {
	printf 'probe.sh: %s\n' "$*" >&2
	exit 2
}

[ "$(uname -s)" = Darwin ] || die "macOS only"
[ -f "$HOME/KEYCHAIN-PROBE-THROWAWAY" ] || die "refusing to run: \$HOME/KEYCHAIN-PROBE-THROWAWAY is missing; use a throwaway account, see README.md"
case $phase in build | gui | ssh | ssh-again | settings | cleanup | ci) ;; *) die "usage: ./probe.sh build|gui|ssh|ssh-again|settings|cleanup|ci" ;; esac

mkdir -p "$here/results" "$install_dir" || exit 2
log=$here/results/$(sw_vers -productVersion)-$(uname -m)-$phase-$(date +%Y%m%dT%H%M%S).log

# Every line reaches the terminal and the log, with $HOME shown as ~, since issue text allows no home path.
out() { sed "s|$HOME|~|g" | tee -a "$log"; }
log_only() { sed "s|$HOME|~|g" >>"$log"; }
say() { printf '\n## %s\n' "$*" | out; }
note() {
	printf '$ %s\n' "$*" | out
	"$@" 2>&1 | out
}

ask() {
	if [ -n "${PROBE_CI-}" ]; then
		printf 'Q: %s\nA: (CI, no human: the screen shows where a call waited)\n' "$1" | log_only
		return
	fi
	printf '\n>>> %s\n> ' "$1" >/dev/tty
	IFS= read -r answer </dev/tty
	printf 'Q: %s\nA: %s\n' "$1" "$answer" | log_only
}

pause() {
	if [ -n "${PROBE_CI-}" ]; then
		printf 'STEP: %s\n' "$1" | log_only
		return
	fi
	printf '\n>>> %s\n    Press Return to continue.' "$1" >/dev/tty
	read -r _ </dev/tty
	printf 'STEP: %s\n' "$1" | log_only
}

# run_at BIN ARG...: runs the probe at BIN; exit 3 means a call blocked, so it asks the human what is on screen.
run_at() {
	bin=$1
	shift
	printf '$ %s %s\n' "$(basename "$bin")" "$*" | out
	watched "$bin" "$@" | out
	if [ "${PIPESTATUS[0]}" = 3 ]; then
		ask "The call blocked. Is a dialog on screen? Type its title, text and buttons, or 'none'. Then dismiss it with Deny or Cancel, never Always Allow."
	fi
}
probe() { run_at "$probe_bin" "$@"; }

read -r -d '' read_screen <<'EOF'
tell application "System Events"
	set out to ""
	repeat with p in (every process whose name is not "Finder")
		repeat with w in (windows of p)
			set out to out & "window of " & (name of p as text) & ": " & (name of w as text) & linefeed
			repeat with e in (entire contents of w)
				try
					if role of e is "AXStaticText" then set out to out & "  text: " & (value of e as text) & linefeed
					if role of e is "AXButton" then set out to out & "  button: " & (name of e as text) & linefeed
				end try
			end repeat
		end repeat
	end repeat
	return out
end tell
EOF

# screen_report: in CI, records what is on screen while a call waits; it touches nothing.
# It logs to stderr, since its caller's stdout is the probe's own output.
screen_report() {
	shot=$here/results/screen-$(date +%H%M%S)-$RANDOM.png
	{
		printf 'CI: the call was still waiting after 8 s\n'
		screencapture -x "$shot" 2>&1 && printf 'screenshot: results/%s\n' "$(basename "$shot")"
		printf 'processes: %s\n' "$(pgrep -l -f 'SecurityAgent|coreauthd|authorizationhost' | tr '\n' ';')"
		osascript -e "$read_screen" 2>&1
	} | out >&2
}

# watched CMD...: runs CMD; in CI, a CMD still running after 8 s gets a screen_report. Returns CMD's status.
watched() {
	if [ -z "${PROBE_CI-}" ]; then
		"$@"
		return
	fi
	"$@" &
	pid=$!
	i=0
	while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 8 ]; do
		sleep 1
		i=$((i + 1))
	done
	if kill -0 "$pid" 2>/dev/null; then screen_report; fi
	wait "$pid"
}

# with_deadline SECS CMD...: runs CMD and kills it after SECS seconds; returns CMD's status.
with_deadline() {
	secs=$1
	shift
	"$@" &
	pid=$!
	(sleep "$secs" && kill "$pid" 2>/dev/null) &
	killer=$!
	wait "$pid"
	rc=$?
	kill "$killer" 2>/dev/null
	return $rc
}

build() {
	command -v cargo >/dev/null || die "cargo is missing: install Rust through rustup on this throwaway account, or copy builds/ from a Mac that has it"
	mkdir -p "$builds" || exit 2
	for r in N N+1; do
		PROBE_RELEASE=$r cargo build --release --locked --manifest-path "$here/Cargo.toml" || die "cargo build failed for release $r"
		cp "$here/target/release/keychain-probe" "$builds/keychain-probe-$r" || exit 2
	done
	for r in N N+1; do
		codesign -dv "$builds/keychain-probe-$r" 2>&1 | grep -E '^(Signature|CDHash)|not signed' | sed "s/^/$r: /"
	done
	[ "$(shasum -a 256 <"$builds/keychain-probe-N")" != "$(shasum -a 256 <"$builds/keychain-probe-N+1")" ] ||
		die "release N and N+1 came out identical: run cargo clean, then ./probe.sh build"
}

# install_release R: puts build R at the shared path through a rename, as an upgrade writes a new file.
install_release() {
	[ -x "$builds/keychain-probe-$1" ] || die "no build for release $1: run ./probe.sh build"
	cp "$builds/keychain-probe-$1" "$install_dir/.keychain-probe.new" || die "copying release $1 failed"
	mv -f "$install_dir/.keychain-probe.new" "$probe_bin" || die "installing release $1 failed"
	say "Install release $1"
	codesign -dv --verbose=2 "$probe_bin" 2>&1 | grep -E '^(Identifier|Format|Signature|CDHash|TeamIdentifier|Runtime)' | out
	codesign -d -r- "$probe_bin" 2>&1 | grep -v '^Executable' | out
	codesign -d --entitlements - "$probe_bin" 2>&1 | grep -v '^Executable' | sed 's/^/entitlements: /' | out
}

context() {
	say "Context"
	note sw_vers
	note uname -m
	note id -un
	if [ -n "${SSH_CONNECTION-}" ]; then via=ssh; else via=local; fi
	printf 'connection: %s\n' "$via" | out
	probe info
}

reads() {
	probe read --api secitem --suppress flag --watchdog 20
	probe read --api secitem --suppress uifail --watchdog 20
	probe read --api secitem --suppress lacontext --watchdog 20
	probe read --api seckeychain --suppress flag --watchdog 20
}

claim7() {
	say "Claim 7: RLIMIT_MEMLOCK in this session ($1), and mlock of a buffer"
	note launchctl limit memlock
	note sh -c 'ulimit -l'
	probe memlock
}

claim5() {
	say "Claim 5: the login keychain's lock settings on this macOS version"
	note security show-keychain-info "$login_kc"
	# macOS 26.4 added -s, which prints the salt; a keychain with a protected entropy file names it there.
	note security show-keychain-info -s "$login_kc"
	probe status --keychain login
}

snapshot() {
	{
		printf 'default keychain: '
		security default-keychain -d user
		printf 'search list:\n'
		security list-keychains -d user
		printf 'login keychain sha256: '
		shasum -a 256 "$login_kc" | cut -d' ' -f1
	} 2>&1 | sed "s|$HOME|~|g"
}

claim6() {
	say "Claim 6: a throwaway keychain file serves the LENDK_TEST_CACHE hook without touching the login keychain"
	tk=${TMPDIR:-/tmp}/lendk-probe-test-$$.keychain-db
	before=$(snapshot)
	printf 'before:\n%s\n' "$before" | out
	probe tempkc-create "$tk"
	printf 'search list right after SecKeychainCreate:\n' | out
	security list-keychains -d user 2>&1 | out
	note security show-keychain-info -s "$tk"
	probe write --keychain "$tk"
	probe read --keychain "$tk"
	probe read --keychain "$tk" --api seckeychain
	# The test item stays in its own file: this read should find nothing.
	probe read --keychain login
	probe delete --keychain "$tk"
	probe tempkc-delete "$tk"
	after=$(snapshot)
	if [ "$before" = "$after" ]; then
		printf 'default keychain, search list and login keychain file: unchanged\n' | out
	else
		{
			printf 'changed between before and after:\n'
			diff <(printf '%s\n' "$before") <(printf '%s\n' "$after")
		} | out
	fi
	note ls -l "$tk"
}

claim1() {
	say "Claim 1: release N+1 reads the item release N wrote, default ACL, interaction disabled"
	install_release N
	probe delete
	probe write --acl default
	probe acl
	probe read
	install_release N+1
	reads
	ask "Did any dialog appear during claim 1's reads, even briefly? Type what it said, or 'none'."
	say "Claim 1 baseline: release N+1 reads with interaction allowed"
	pause "A dialog may now ask to use confidential information stored in the keychain. Note its exact text and buttons, then click Deny, never Always Allow."
	probe read --suppress none --watchdog 120
	ask "What did the dialog say and offer, and which button did you click? Type 'none' if no dialog appeared."
	say "Claim 1, follow-on: release N+1 replaces the item, as the first lendk unlock after an upgrade would"
	probe delete --watchdog 20
	probe write --acl default --watchdog 20
	probe acl
	probe read
}

claim2() {
	say "Claim 2: an item whose ACL trusts any application reads from every build without a prompt"
	# The item's owner deletes it: release N+1 when claim 1's follow-on replaced it, else release N.
	probe delete --watchdog 20
	install_release N
	probe delete --watchdog 20
	probe write --acl any
	probe acl
	install_release N+1
	reads
	probe read --suppress none --watchdog 60
	elsewhere=${TMPDIR:-/tmp}/keychain-probe-elsewhere
	cp "$builds/keychain-probe-N+1" "$elsewhere" || exit 2
	say "Claim 2: the same build from another path"
	run_at "$elsewhere" read --watchdog 20
	run_at "$elsewhere" read --suppress none --watchdog 60
	rm -f "$elsewhere"
	say "Claim 2: Apple's security tool, interaction allowed, the value discarded"
	watched with_deadline 60 security find-generic-password -s lendk-probe -a "$account" -w >/dev/null 2>&1
	printf 'security find-generic-password -w: exit %s\n' "$?" | out
	ask "Did any dialog appear during claim 2? Type what it said and which button you clicked, or 'none'."
	probe delete --watchdog 20
}

claim4() {
	say "Claim 4: suppressing the Unlock Keychain dialog while the login keychain is locked"
	install_release N
	probe delete --watchdog 20
	probe write --acl default
	probe lock --keychain login
	probe status --keychain login
	reads
	probe unlock --no-password --watchdog 20
	ask "Did an Unlock Keychain dialog appear during the locked reads, even briefly? Type what it said, or 'none'."
	say "Claim 4 baseline: the same read with interaction allowed"
	pause "An Unlock Keychain dialog may now appear. Note its exact text and buttons, then click Cancel."
	probe read --suppress none --watchdog 120
	ask "What did the dialog say, and which button did you click? Type 'none' if no dialog appeared."
	say "Claim 4: SecKeychainUnlock with the login password"
	if [ -n "${PROBE_CI-}" ]; then
		printf '%s\n' "CI: the runner's login password is unknown, so its login keychain stays locked from here on" | out
		return
	fi
	probe status --keychain login
	probe unlock --watchdog 120
	probe status --keychain login
	probe read
	probe delete
}

claim3() {
	say "Claim 3: the login keychain from an ssh session"
	probe status --keychain login
	probe delete --watchdog 20
	probe write --acl default --watchdog 20
	reads
	probe unlock --no-password --watchdog 20
	pause "Next the probe asks for this account's login password and calls SecKeychainUnlock, the only unlock open to lendk over ssh."
	probe unlock --watchdog 120
	probe status --keychain login
	probe write --acl default --watchdog 20
	reads
}

finish() {
	# TN3137: macOS logs its use of protected entropy files, new in 26.4, under this category.
	note log show --last 30m --style compact --predicate 'category == "dp_login"'
	ask "Anything else seen on screen or in the terminal during this run that the log does not show? Type it, or 'none'."
	printf '\nResults: %s\n' "$log" | out
}

case $phase in
build)
	build
	;;
gui)
	install_release N
	context
	ask "Is this Terminal window running in this throwaway user's own GUI login session, not over ssh or su? [y/n]"
	claim7 "GUI login session"
	claim5
	probe delete
	claim6
	claim1
	claim2
	claim4
	finish
	;;
ssh)
	install_release N
	context
	ask "Is this same user logged in at the Mac's GUI right now, with that session open? Fast user switching counts. [y/n]"
	claim7 "ssh session"
	claim3
	pause "Leave this session open. In a second ssh session to this account, run: ./probe.sh ssh-again. Come back here once it finishes."
	say "Claim 3: the first ssh session after the second one ran"
	probe status --keychain login
	reads
	probe delete --watchdog 20
	claim6
	finish
	;;
ssh-again)
	context
	ask "Is this user logged in at the GUI right now? Is another ssh session of this user open? Answer both."
	say "Claim 3: a later ssh session"
	probe status --keychain login
	reads
	finish
	;;
settings)
	install_release N
	context
	claim7 "$(if [ -n "${SSH_CONNECTION-}" ]; then echo ssh session; else echo GUI login session; fi)"
	claim5
	finish
	;;
ci)
	install_release N
	context
	claim7 "CI job"
	claim5
	probe delete
	claim6
	claim1
	claim2
	claim4
	finish
	;;
cleanup)
	install_release N
	probe delete --watchdog 20
	with_deadline 30 security delete-generic-password -s lendk-probe -a "$account" >/dev/null 2>&1
	printf 'security delete-generic-password: exit %s\n' "$?" | out
	rm -f "$probe_bin" "${TMPDIR:-/tmp}"/lendk-probe-test-*.keychain-db
	note security list-keychains -d user
	;;
esac
