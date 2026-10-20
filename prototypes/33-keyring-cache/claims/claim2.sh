#!/bin/sh
# PROTOTYPE for #33, throwaway. Claim 2: one @u key reads from separate ssh logins, tmux panes after
# the starting login ends, systemd user services, a background job outliving its login, and
# Claude Code's sandbox; cron and sudo added. Each context runs `ctx`, then `get` plain and with
# @u linked into the thread keyring first (possess).
set -u
. "$(dirname "$0")/lib.sh"
probe='keyprobe ctx; keyprobe get lendk:claim2 plain; keyprobe get lendk:claim2 possess'

say "claim 2: put from login A ($(stamp))"
as_alice 'keyprobe put lendk:claim2 3600 staged c2'

say "2a: a second ssh login, while login C runs alongside"
as_alice 'sleep 20' &
sleep 3
as_alice "$probe"
wait

say "2b: tmux pane, before and after the login that started tmux ends"
as_alice "tmux new-session -d -s proto33; tmux send-keys -t proto33 '{ $probe; } >/tmp/tmux-before.log 2>&1' Enter; sleep 3; cat /tmp/tmux-before.log"
sleep 5
as_alice "tmux send-keys -t proto33 '{ $probe; } >/tmp/tmux-after.log 2>&1' Enter; sleep 3; cat /tmp/tmux-after.log; tmux kill-server"

say "2c: systemd user service, alice logged in"
as_alice "systemd-run --user --wait --pipe --quiet sh -c '$probe'"

say "2d: background job started with setsid from a login that then ends (stand-in for Claude Code's daemon)"
as_alice "setsid -f sh -c 'sleep 15; { $probe; } >/tmp/bg.log 2>&1' </dev/null >/dev/null 2>&1"
sleep 25
as_alice 'cat /tmp/bg.log'

say "2e: cron job"
as_alice "printf '* * * * * { $probe; } >/tmp/cron.log 2>&1\n' | crontab -"
sleep 75
as_alice 'cat /tmp/cron.log; crontab -r'

say "2f: sudo -u alice from ops's login"
as_ops "sudo -u alice sh -c '$probe'; echo '-- sudo -iu alice:'; sudo -iu alice sh -c '$probe'"

say "2g: bubblewrap with a user namespace, as Claude Code's Linux sandbox runs commands"
as_alice "bwrap --unshare-user --dev-bind / / sh -c '$probe'"

say "2h: Claude Code's sandbox runtime (srt), if installed"
as_alice "export PATH=\$HOME/node-v22.12.0-linux-x64/bin:\$HOME/.npm-global/bin:\$PATH; srt --version && srt -c '$probe'"

say "2i: systemd user service after logout, with lingering on"
as_ops 'sudo loginctl enable-linger alice'
as_alice "systemd-run --user --on-active=40 --unit=proto33-late sh -c '{ $probe; } >/tmp/svc-late.log 2>&1'"
alice_logged_out
sleep 45
as_ops 'sudo cat /tmp/svc-late.log; sudo loginctl disable-linger alice'

say "2j: 2g and 2h again, with Ubuntu's AppArmor restriction on unprivileged user namespaces lifted"
as_ops 'sudo sysctl -q kernel.apparmor_restrict_unprivileged_userns=0'
as_alice "bwrap --unshare-user --dev-bind / / sh -c '$probe'; echo '-- srt'
	export PATH=\$HOME/node-v22.12.0-linux-x64/bin:\$HOME/.npm-global/bin:\$PATH; srt -c '$probe'"
as_ops 'sudo sysctl -q kernel.apparmor_restrict_unprivileged_userns=1'
