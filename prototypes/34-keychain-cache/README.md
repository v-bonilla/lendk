# Keychain probe, a prototype for #34

Throwaway code. It lives on the `prototype/keychain-cache` branch, which never merges, and answers one question from [#34](https://github.com/v-bonilla/lendk/issues/34): does a login keychain item hold the unlocked identity as [#23](https://github.com/v-bonilla/lendk/issues/23) relies on? #23 caches the identity in a login keychain generic password, service `lendk`, account the recipient, with every keychain call made with user interaction disabled.

- `src/main.rs`: `keychain-probe`, a Rust binary built with the crates [#27](https://github.com/v-bonilla/lendk/issues/27) admits for the keychain, `security-framework-sys` and `core-foundation-sys`, pinned exactly. Each command prints one `probe:` line per result. Its `extra` module declares what those crates lack.
- `probe.sh`: the driver. It walks a human through the claims, asks what is on screen when a call blocks, and logs everything to `results/`. Its `ci` phase runs the claims a CI runner can check with nobody at the screen.

## Before you start

- Use a throwaway macOS account or VM, never the maintainer's own account. The probe writes an item into the login keychain, locks the keychain and unlocks it again.
- Create the guard file on that account: `touch ~/KEYCHAIN-PROBE-THROWAWAY`. The probe and the driver refuse to run without it.
- Install the Xcode Command Line Tools and Rust through rustup on that account, or copy `builds/` from another Mac.
- Turn on Remote Login for claim 3.
- An Apple Silicon Mac matches a 2.0 release best: its linker signs every binary ad hoc, as [#31](https://github.com/v-bonilla/lendk/issues/31) ships them. On an Intel Mac the log shows whether the linker signed at all.

Every dialog gets Deny or Cancel, never Always Allow, which would change the item's ACL and spoil later steps.

## Run it

1. Log in to the throwaway account at the GUI and open Terminal in this directory.
2. `./probe.sh build` builds release N and release N+1, which differ only in an embedded string, so their ad-hoc signatures differ.
3. `./probe.sh gui` runs claims 1, 2, 4, 5, 6 and 7, in about ten minutes.
4. Keep that GUI session logged in. From another machine, ssh to the account, `cd` here and run `./probe.sh ssh`. Midway it asks for `./probe.sh ssh-again` from a second ssh session.
5. Log out of the GUI, or reboot without logging in there, and repeat step 4.
6. Close every ssh session, ssh in once more and run `./probe.sh ssh-again`, to see whether an unlock made over ssh outlives its session.
7. On each other macOS version at hand, out of 14, 15 and 26, run `./probe.sh settings` as a fresh account for claims 5 and 7, or the whole `gui` run.
8. `./probe.sh cleanup` removes the item and the installed probe.

Each run writes `results/VERSION-ARCH-PHASE-TIME.log`, with home paths shown as `~`. Paste the logs into #34, or hand them to Claude to write the findings comment.

## On the CI runners

A push to `prototype/keychain-cache` runs `.github/workflows/keychain-probe.yml` on `macos-14`, `macos-15`, `macos-26` and `macos-26-intel`. Each job builds release N and N+1, runs `PROBE_CI=1 ./probe.sh ci` and uploads `results/` as an artifact.

- The runner's account logs in at the GUI automatically, which opens its login keychain, and the image never changes that keychain's lock settings (`configure-autologin.sh` and `change_password` in `actions/runner-images`). Its runner builds with the same linker signature as #31's release workflow.
- Nobody answers a dialog. A call still waiting after 8 s gets a screenshot and a dump of the windows on screen through System Events, and the probe's watchdog then ends it. The driver clicks nothing.
- `ci` covers claims 1, 2, 4, 5, 6 and 7 for the job's own session. Read `graphic_access` in the first `info` line first: with `no`, the job runs outside the GUI session, and claims 1 and 4 show what a background process sees rather than the dialog case.
- `ci` leaves out claim 3, claim 7 over ssh and claim 4's unlock with the login password, which the runner keeps. They need a Mac, or a CI job that starts sshd and makes a second account. [#36](https://github.com/v-bonilla/lendk/issues/36) adds that job in `../36-keychain-ssh/`, on the `prototype/keychain-ssh` branch.

## Where each claim's answer shows

| Claim | Phase | What to read in the log |
| --- | --- | --- |
| 1, release N+1 reads release N's item | `gui`, `ci` | The four reads after `Install release N+1`: `status`, `name`, `result=blocked` and `item`. The baseline's dialog answer. Whether N+1's `delete` and `write` succeed, which decides what the first `lendk unlock` after an upgrade can do. |
| 2, an ACL that trusts any application | `gui`, `ci` | `acl` shows `apps=any` on the decrypt entries, and the partition list. The reads from release N+1, from a copy at another path, and through `security find-generic-password`. |
| 3, over ssh | `ssh`, `ssh-again` | `info` shows `remote` and `graphic_access`. `status` shows `unlocked`. The reads before and after `unlock` with the login password, and in the later sessions. |
| 4, suppressing the Unlock Keychain dialog | `gui`, `ci` | The locked reads, one per suppression: `flag` is `SecKeychainSetUserInteractionAllowed(false)`, `uifail` is `kSecUseAuthenticationUIFail`, `lacontext` is an `LAContext` with `interactionNotAllowed`. The last two exist only for SecItem queries, so the `seckeychain` read runs with the flag alone. |
| 5, lock settings and macOS 26.4 | `gui`, `settings`, `ci` | `lock_on_sleep`, `use_lock_interval` and `lock_interval_s`, and `security show-keychain-info`. The `dp_login` log lines at the end of each run. |
| 6, a throwaway keychain for `LENDK_TEST_CACHE` | `gui`, `ssh`, `ci` | The settings a new keychain starts with, the search list right after `SecKeychainCreate`, and the before and after snapshot of the default keychain, the search list and the login keychain file. |
| 7, `RLIMIT_MEMLOCK` | `gui`, `ssh`, `settings`, `ci` | `rlimit_memlock_soft` and `rlimit_memlock_hard`, and `mlock` for buffers of 4 KiB to 64 MiB. |

## macOS 26.4 and keychain files

[TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains), in its section "Backing up a file-based keychain", added on 2026-09-24:

- From macOS 26.4 a keychain file may reference a protected entropy file in `/var/db/SystemKeys`, and unlocking it takes both the password and that file. A copied keychain file no longer opens on another Mac without it.
- The login keychain references one; not every keychain file does. `security show-keychain-info -s` prints the salt that names the entropy file.
- macOS logs its use of these files under the `dp_login` category.

Claim 5 checks what this means for a generic password item, and claim 6 whether a keychain the suite creates gets an entropy file.

## What lendk would bind itself

`security-framework-sys` 2.17.0 and `core-foundation-sys` 0.8.7 lack these, so `src/main.rs` declares them in `extra`, as lendk would under #27:

- `SecAccessCreate`, `SecAccessCopyACLList`, `SecAccessCopyMatchingACLList`, `SecACLCopyAuthorizations`, `SecACLCopyContents`, `SecACLSetContents`, `SecKeychainItemCopyAccess` and `kSecACLAuthorizationDecrypt`, for claim 2's ACL;
- `SecTrustedApplicationCopyData`, `SecTrustedApplicationCopyRequirement` and `SecRequirementCopyString`, to print an ACL;
- `kSecAttrAccess` and `kSecUseAuthenticationUIFail`;
- `SecKeychainGetStatus`, `SecKeychainLock`, `SecKeychainDelete`, `SecKeychainCopySettings` and `SecKeychainGetPath`;
- `SessionGetInfo`, to tell an ssh session from a GUI one;
- the Objective-C runtime and `LAContext`, for `interactionNotAllowed`.

## Safety

- The item holds a fixed dummy string. The probe prints only whether a read returned it and which release wrote it.
- `unlock` reads the login password with echo off, passes it to `SecKeychainUnlock` and zeroes it. Nothing prints or logs it.
- Every item the probe touches has service `lendk-probe`, apart from the throwaway keychain claim 6 creates in `$TMPDIR` and deletes.
