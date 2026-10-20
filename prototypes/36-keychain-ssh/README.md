# Keychain probe over ssh, a prototype for #36

Throwaway code. It lives on the `prototype/keychain-ssh` branch, cut from `prototype/keychain-cache`, which never merges. It answers one question from [#36](https://github.com/v-bonilla/lendk/issues/36): does lendk 2.0's identity cache, a login keychain item ([#23](https://github.com/v-bonilla/lendk/issues/23), checked in [#34](https://github.com/v-bonilla/lendk/issues/34)), work for a Mac user over ssh?

- `ssh-ci.sh` runs #34's probe, `../34-keychain-cache/probe.sh`, in ssh sessions from a GitHub-hosted macOS runner to itself. It drives two accounts: the runner's own, whose GUI session holds its login keychain open, and `lendkprobe`, which it adds and which never logs in at the GUI.
- `.github/workflows/keychain-ssh-probe.yml` runs it on each push to the branch, on `macos-14`, `macos-15`, `macos-26` and `macos-26-intel`, and uploads `results/` as an artifact.
- `probe.sh` gained what CI needs: a `write` phase, an `ssh-login` phase, a second ssh session it opens itself, and an unlock that reads the login password from a file. The probe binary gained `tempkc-create --login-password`, which makes a keychain with the password read from stdin.

## What the job does

1. Builds release N and N+1 with `./probe.sh build`. The sessions use release N alone.
2. Writes `/etc/ssh/sshd_config.d/000-lendk-probe.conf`, which allows key logins only, from 127.0.0.1 only, for the two accounts. It stops unless `sshd -T` shows all three settings.
3. Turns on Remote Login, unless port 22 already answers.
4. Adds `lendkprobe` with a random password, and gives it a copy of the probe, the guard file and a file holding that password, readable by it alone.
5. Gives each account an ssh key to itself, and an ssh config naming that login `lendk-probe-self`.
6. Runs the sessions below in order. Each one logs to its own file in `results/`.
7. Copies `lendkprobe`'s logs to `results/lendkprobe/`, and sshd's system log to the `-ssh-ci-…-sshd.log` file.

The job clicks nothing and ends no process.

## Sessions and claims

Claims use #36's numbering.

| Session | Account | How it runs | Phase | Claim |
| --- | --- | --- | --- | --- |
| 1 | runner | the job's own, in the GUI login | `write` | sets up 1 |
| 2 | runner | ssh | `ssh` | 1, 4 |
| 3 | runner | a second ssh, while 2 stays open | `ssh-again` | 1 |
| 4 | `lendkprobe` | ssh | `ssh` | 3, 4 |
| 5 | `lendkprobe` | a second ssh, while 4 stays open | `ssh-again` | 3 |
| 6 | `lendkprobe` | ssh | `ssh-login` | 2, stand-in |
| 7 | `lendkprobe` | a second ssh, while 6 stays open | `ssh-again` | 2, stand-in |
| 8 | `lendkprobe` | ssh, once 6 and 7 have ended | `ssh-again` | 2, stand-in |

## Where each claim's answer shows

| Claim | What to read in the log |
| --- | --- |
| 1, an ssh session reads the item while the GUI session holds the login keychain open | Session 2's first `info` line (`remote`, `graphic_access`, `session_id`), its `status --keychain login`, its first `read`, which finds the item session 1 wrote, then its own write and reads. Session 3's `status` and reads. |
| 2, what `SecKeychainUnlock` with the login password does over ssh, and whether its unlock outlives the session | Session 6's `status` after `lock`, its reads while locked, `unlock` with `password=typed`, then `status` and reads. Session 7's `status`, from a concurrent session, and session 8's, from a later one. The `pgrep` list between 7 and 8 shows what still ran as `lendkprobe`. |
| 3, whether an account that only ever logged in over ssh has a login keychain | Session 4's `keychains` notes (`ls` of `~/Library/Keychains`, `security login-keychain`, `default-keychain` and `list-keychains`), the `default_keychain` field of `info`, then `status`, `write`, the reads and both `unlock`s. |
| 4, `RLIMIT_MEMLOCK` over ssh | The claim 7 section of sessions 2 and 4: `launchctl limit memlock`, `ulimit -l`, `rlimit_memlock_soft`, `rlimit_memlock_hard` and `mlock` from 4 KiB to 64 MiB. |

## What the stand-in does not show

Claim 2 asks about a login keychain made by a GUI login, once that GUI session has logged out. CI cannot log its runner out of the GUI, nor log `lendkprobe` in there. Session 6 stands in for it:

- It makes `lendkprobe` a login keychain with `SecKeychainCreate` and its login password.
- It sets that keychain as the login, default and only keychain.
- It turns its lock timer and lock on sleep off, as a real login keychain has them (#34, claim 5).
- Then it locks the keychain and unlocks it over ssh.

It differs from the real case in three ways:

- loginwindow made none of it;
- on macOS 26 a login keychain a GUI login made references a protected entropy file (#34, claim 5), and this one may not;
- no GUI logout ran, which may itself lock or release the keychain.

So it settles what an ssh session can do with a locked keychain and the login password. A Mac still settles the GUI logout itself, through steps 5 and 6 of `../34-keychain-cache/README.md`.

## Safety

- `ssh-ci.sh` refuses to run unless it is on macOS with `GITHUB_ACTIONS=true` and `RUNNER_ENVIRONMENT=github-hosted`: a VM thrown away after the job.
- sshd takes keys only, from 127.0.0.1 only, for the two accounts only.
- `lendkprobe`'s password is random per job and masked in the job log. It reaches `sysadminctl` on argv, as root, and the probe on stdin from a file only `lendkprobe` reads. The logs replace it with `<password>` if it ever shows.
- The checkout keeps no token (`persist-credentials: false`), since `lendkprobe` may read the runner's work directory.
- The probe's own safety rules hold: the item holds a fixed dummy, and every item has service `lendk-probe`.
