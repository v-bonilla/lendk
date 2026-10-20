#!/bin/bash
# PROTOTYPE for lendk #36, throwaway, never merged: on a GitHub-hosted macOS runner, runs #34's probe in ssh sessions from the runner to itself,
# as the runner's account, whose GUI session holds its login keychain open, and as a second account that never logs in at the GUI.
# Usage, from the workflow: ../36-keychain-ssh/ssh-ci.sh, after ./probe.sh build in ../34-keychain-cache. README.md gives the sessions.
# It turns on Remote Login and adds an account, so it refuses to run anywhere but a GitHub-hosted runner, a VM thrown away after the job.
set -u

here=$(cd "$(dirname "$0")" && pwd)
probe_dir=$(cd "$here/../34-keychain-cache" && pwd)
me=$(id -un)
second=lendkprobe
second_home=/Users/$second
# Random per job, masked in the job log, and shown in any log as <password>.
password=$(openssl rand -hex 16)

die() {
	printf 'ssh-ci.sh: %s\n' "$*" >&2
	exit 2
}

[ "$(uname -s)" = Darwin ] && [ "${GITHUB_ACTIONS-}" = true ] && [ "${RUNNER_ENVIRONMENT-}" = github-hosted ] ||
	die "refusing to run: this turns on Remote Login and adds an account, so it runs only on a GitHub-hosted macOS runner"
[ -x "$probe_dir/builds/keychain-probe-N" ] || die "no build: run ./probe.sh build in ../34-keychain-cache first"
[ -n "$password" ] || die "openssl rand failed"
printf '::add-mask::%s\n' "$password"

mkdir -p "$probe_dir/results" || exit 2
log=$probe_dir/results/$(sw_vers -productVersion)-$(uname -m)-ssh-ci-$(date +%Y%m%dT%H%M%S).log

out() { sed -e "s|$HOME|~|g" -e "s|$second_home|~$second|g" -e "s|$password|<password>|g" | tee -a "$log"; }
say() { printf '\n## %s\n' "$*" | out; }
note() {
	printf '$ %s\n' "$*" | out
	"$@" 2>&1 | out
}

# ssh_key USER: an ssh key that logs USER in to this runner from itself, and a config naming that login lendk-probe-self.
ssh_key() {
	sudo -u "$1" -H sh -c '
		cd && umask 077 && mkdir -p .ssh &&
			{ [ -f .ssh/lendk-probe ] || ssh-keygen -q -t ed25519 -N "" -C lendk-probe-36 -f .ssh/lendk-probe; } &&
			cat .ssh/lendk-probe.pub >>.ssh/authorized_keys &&
			printf "%s\n" "Host lendk-probe-self" "  HostName 127.0.0.1" "  User $1" "  IdentityFile ~/.ssh/lendk-probe" \
				"  IdentitiesOnly yes" "  BatchMode yes" "  StrictHostKeyChecking accept-new" \
				"  UserKnownHostsFile ~/.ssh/lendk-probe-known-hosts" >.ssh/lendk-probe-config' sh "$1" ||
		die "setting up the ssh key of $1 failed"
	note sudo -u "$1" -H sh -c 'cd && ls -ld . .ssh .ssh/authorized_keys'
}

# ssh_as USER COMMAND: one ssh session to this runner as USER, running COMMAND. probe.sh logs it to its own file.
ssh_as() {
	user=$1
	shift
	printf '$ ssh %s@127.0.0.1 %s\n' "$user" "$*" | out
	sudo -u "$user" -H sh -c 'cd && exec ssh -F .ssh/lendk-probe-config lendk-probe-self "$1"' sh "$*" </dev/null 2>&1
	printf 'ssh session as %s: exit %s\n' "$user" "$?" | out
}

say "Remote Login before this job"
note sw_vers
if nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1; then was_on=yes; else was_on=no; fi
printf 'port 22 on 127.0.0.1 answers: %s\n' "$was_on" | out
sudo launchctl print-disabled system 2>&1 | grep -i openssh | out

say "Restrict sshd to key logins from this runner to itself, for the probe's two accounts"
note grep -n '^Include' /etc/ssh/sshd_config
conf=/etc/ssh/sshd_config.d/000-lendk-probe.conf
printf '%s\n' "# PROTOTYPE for lendk #36: key logins from this runner to itself only, for the probe's two accounts." \
	"PasswordAuthentication no" "KbdInteractiveAuthentication no" "AllowUsers $me@127.0.0.1 $second@127.0.0.1" |
	sudo tee "$conf" >/dev/null || die "writing $conf failed"
ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || note sudo ssh-keygen -A
effective=$(sudo sshd -T -C "user=$second,host=127.0.0.1,addr=127.0.0.1" 2>&1)
printf '%s\n' "$effective" | grep -E '^(usepam|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|allowusers) ' | out
for want in 'passwordauthentication no' 'kbdinteractiveauthentication no' "allowusers $second@127.0.0.1"; do
	printf '%s\n' "$effective" | grep -qx "$want" || die "sshd does not show '$want' from $conf, so Remote Login stays as it was"
done

if [ "$was_on" = no ]; then
	say "Turn on Remote Login"
	note sudo launchctl enable system/com.openssh.sshd
	note sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist
	nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1 || note sudo systemsetup -f -setremotelogin on
	i=0
	until nc -z -G 1 127.0.0.1 22 >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -le 10 ] || die "port 22 on 127.0.0.1 still does not answer"
		sleep 1
	done
fi

say "Add $second, an account that never logs in at the GUI"
id "$second" >/dev/null 2>&1 && die "$second already exists"
printf '$ sudo sysadminctl -addUser %s -fullName ... -home ~%s -password <password>\n' "$second" "$second" | out
sudo sysadminctl -addUser "$second" -fullName "lendk probe for issue 36" -home "$second_home" -password "$password" 2>&1 | out
note sudo createhomedir -c -u "$second"
id "$second" >/dev/null 2>&1 || die "adding $second failed"
note id "$second"
note dscl . -read "/Users/$second" NFSHomeDirectory UserShell
if dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
	note sudo dseditgroup -o edit -a "$me" -t user com.apple.access_ssh
	note sudo dseditgroup -o edit -a "$second" -t user com.apple.access_ssh
fi

say "Give $second the probe, its guard file and its login password, readable by $second alone"
{ sudo mkdir -p "$second_home/probe" &&
	sudo cp -R "$probe_dir/probe.sh" "$probe_dir/builds" "$second_home/probe/" &&
	sudo chown -R "$second:staff" "$second_home/probe" &&
	sudo -u "$second" -H sh -c 'cd && touch KEYCHAIN-PROBE-THROWAWAY'; } || die "giving $second the probe failed"
printf '%s\n' "$password" | sudo -u "$second" -H sh -c 'cd && umask 077 && cat >.lendk-probe-password' ||
	die "writing the password file of $second failed"
note sudo -u "$second" -H sh -c 'cd && ls -l .lendk-probe-password KEYCHAIN-PROBE-THROWAWAY probe'

say "ssh keys from this runner to itself"
ssh_key "$me"
ssh_key "$second"

say "Session 1, the job's own in $me's GUI login: ./probe.sh write"
(cd "$probe_dir" && PROBE_CI=1 ./probe.sh write)

say "Sessions 2 and 3, ssh as $me while its GUI session holds the login keychain open: ./probe.sh ssh"
ssh_as "$me" "cd '$probe_dir' && PROBE_CI=1 ./probe.sh ssh"

say "Sessions 4 and 5, ssh as $second, which never logged in at the GUI: ./probe.sh ssh"
ssh_as "$second" "cd ~/probe && PROBE_CI=1 ./probe.sh ssh"

say "Sessions 6 and 7, ssh as $second: ./probe.sh ssh-login, a stand-in login keychain locked and unlocked over ssh"
ssh_as "$second" "cd ~/probe && PROBE_CI=1 ./probe.sh ssh-login"

say "Once every ssh session of $second has ended: what still runs as $second"
sleep 5
note pgrep -l -u "$second"

say "Session 8, ssh as $second again: ./probe.sh ssh-again"
ssh_as "$second" "cd ~/probe && PROBE_CI=1 ./probe.sh ssh-again"

say "Collect $second's logs and sshd's log"
sudo mkdir -p "$probe_dir/results/$second" &&
	sudo cp -R "$second_home/probe/results/." "$probe_dir/results/$second/" &&
	sudo chown -R "$me" "$probe_dir/results/$second"
sudo log show --last 30m --style compact --predicate 'process BEGINSWITH "sshd"' 2>&1 |
	sed -e "s|$HOME|~|g" -e "s|$second_home|~$second|g" -e "s|$password|<password>|g" >"${log%.log}-sshd.log"
find "$probe_dir/results" -type f | sort | out
