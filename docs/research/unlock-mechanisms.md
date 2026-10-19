# Daemonless ways to keep the store unlocked between calls

Research for [#18](https://github.com/v-bonilla/lendk/issues/18), a child of the lendk 2.0 wayfinder map [#15](https://github.com/v-bonilla/lendk/issues/15). It states facts and decides nothing: [#23](https://github.com/v-bonilla/lendk/issues/23) picks the unlock model.

In 1.x the GnuPG key protects the store, and gpg-agent's passphrase cache keeps it usable between calls ([ADR 0007](../adr/0007-no-daemon-no-value-cache.md)). This note calls the 2.0 counterpart of the GnuPG key the **store key**: whatever decrypts the store, in the form [#17](https://github.com/v-bonilla/lendk/issues/17) picks. The store is **unlocked** when a fresh lendk process can obtain the store key without a prompt. Every call is a fresh process, so whatever holds the unlock must outlive the process that made it.

Sources were read on 2026-10-19. Host observations come from a Debian 13 machine (kernel 6.12, systemd 257). No key was added to any keyring and nothing was measured; the open questions at the end list what a prototype must confirm.

## Summary

- **Linux has a cache with no daemon at all: the kernel keyring.** The user keyring and the persistent keyring reach every process of the user, so separate ssh logins, tmux panes and systemd user services all see one unlock. A session keyring does not: each ssh login gets its own, pam_keyinit revokes it at logout, and tmux panes keep a revoked one after the login that started the tmux server ends.
- **macOS has no kernel keyring.** An item in the login keychain reads without a prompt while that keychain is open. The keychain opens at GUI login and an ssh login does not open it. Apple's security server holds that state, as gpg-agent holds the passphrase in 1.x.
- **Touch ID does not span calls.** Biometric access control needs either the data protection keychain, which needs a provisioning profile, or CryptoKit Secure Enclave keys. Either way an authentication lasts one process, so each call needs a finger.
- **Hardware tokens work on both platforms but hold the unlock for seconds.** A YubiKey caches a touch for 15 s. Its cached PIN ends when the PC/SC stack powers the idle card off, after 5 s in pcsc-lite. FIDO2 `hmac-secret` needs a touch per assertion unless the token accepts silent assertions.
- **ssh-agent works on both platforms** and can hold an Ed25519 key from which the store key is derived. It is a daemon: OpenSSH's, not lendk's.
- **A key file with mode 0600 works on both platforms** with no daemon, and is never locked.
- **No single daemonless mechanism keeps the store unlocked on both platforms.** Each platform has one cache that runs no lendk daemon: the kernel keyring on Linux, and the login keychain on macOS, inside Apple's security server. Across both, only the key file and ssh-agent work, and ssh-agent is a daemon.

## What each mechanism is checked for

The ticket asks five things of each mechanism:

- **Locked store.** What a non-interactive call sees when the store is locked. ADRs [0003](../adr/0003-interactive-when-stdin-or-stderr-is-a-tty.md) and [0004](../adr/0004-fail-fast-classify-by-status-code.md) require it to fail fast with the `locked` class and never wait on a prompt.
- **Daemon.** Whether some daemon runs anyway, and whose it is. [ADR 0007](../adr/0007-no-daemon-no-value-cache.md) forbids a lendk daemon. It allowed gpg-agent, which is GnuPG's.
- **Human's controls.** The lifetime and flush controls the human keeps, as `default-cache-ttl`, `max-cache-ttl` and `gpgconf --reload gpg-agent` are in 1.x.
- **Rust crates** that reach the mechanism.
- **Same-user reach.** What a same-user process can read. [ADR 0008](../adr/0008-same-user-threats-out-of-scope.md) puts same-user processes out of scope, but the README's Security model states the reach, so each mechanism's reach is listed.

## Linux kernel keyring

The kernel keeps its keys in unswappable kernel memory, organised in keyrings, and reaches them through `add_key(2)`, `request_key(2)` and `keyctl(2)` ([keyrings(7)](https://man7.org/linux/man-pages/man7/keyrings.7.html)). A `user` key holds up to 32,767 bytes that user space can read back. A `logon` key cannot be read from user space, so it cannot hand lendk a store key. The `keyctl` command comes from keyutils and is optional: lendk would make the system calls itself.

### Which keyring a fresh process reaches

- **Session keyring (`@s`).** It is inherited across `fork` and kept across `execve`, and it is destroyed when the last process referring to it exits ([session-keyring(7)](https://man7.org/linux/man-pages/man7/session-keyring.7.html)). `pam_keyinit force revoke` gives each login its own session keyring and revokes it when the login ends ([pam_keyinit(8)](https://man7.org/linux/man-pages/man8/pam_keyinit.8.html)). Debian 13 runs that line for sshd, `login` and the systemd user manager (`/etc/pam.d/sshd` line 25, `/usr/lib/pam.d/systemd-user`).
- **User keyring (`@u`).** One per UID, shared by every process with that UID ([user-keyring(7)](https://man7.org/linux/man-pages/man7/user-keyring.7.html)). It also gets the possessor's rights: the kernel resolves `KEY_SPEC_USER_KEYRING` to a possessed reference ([process_keys.c](https://github.com/torvalds/linux/blob/v6.12/security/keys/process_keys.c#L696-L701)).
- **User session keyring (`@us`).** It stands in for a missing session keyring and links to `@u` ([user-session-keyring(7)](https://man7.org/linux/man-pages/man7/user-session-keyring.7.html)).
- **Persistent keyring.** One per UID per user namespace. A process reaches it with `KEYCTL_GET_PERSISTENT`, which links it into one of the caller's keyrings ([persistent-keyring(7)](https://man7.org/linux/man-pages/man7/persistent-keyring.7.html), [keyctl_get_persistent(3)](https://man7.org/linux/man-pages/man3/keyctl_get_persistent.3.html)). It needs `CONFIG_PERSISTENT_KEYRINGS`, which the Debian 13 kernel sets.

### Lifetimes

| Keyring | Separate ssh logins | tmux panes | systemd user services | After the last login ends | Docker container |
|---|---|---|---|---|---|
| Session `@s` | Not shared: each login has its own | Shared by the panes of one tmux server, and revoked when the login that started the server ends | Not shared: services share the user manager's own | Revoked | Unreachable |
| User `@u` | Shared | Shared | Shared | Kept until reboot (Linux 5.3 and later) | Unreachable |
| Persistent | Shared | Shared | Shared | Kept until it expires, by default 3 days after the last request, or reboot | Unreachable |

- **tmux.** The tmux server is forked from the client that started it, so it keeps that login's session keyring, and its panes inherit it ([session-keyring(7)](https://man7.org/linux/man-pages/man7/session-keyring.7.html)). When that login ends, `pam_keyinit revoke` revokes the keyring under the panes. An SPDK maintainer traced an `add_key: Key has been revoked` failure on `@s` to a revoked session keyring, and has seen it in long-running tmux sessions ([spdk#3492](https://github.com/spdk/spdk/issues/3492)).
- **systemd user services.** `KeyringMode=` defaults to `inherit` for services of the user manager ([systemd.exec(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#KeyringMode=)), so they share the manager's session keyring. On Debian 13 the manager runs its own PAM session with `pam_keyinit force revoke`. It stops 10 s after the user's last session ends (`UserStopDelaySec=`, [logind.conf(5)](https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html)), unless lingering keeps it running from boot ([loginctl(1)](https://www.freedesktop.org/software/systemd/man/latest/loginctl.html)).
- **`@u` after logout.** The man pages tie `@u` to the kernel's record of the UID, destroyed when the user's last process exits ([user-keyring(7)](https://man7.org/linux/man-pages/man7/user-keyring.7.html)). The same page adds that a link from another keyring pins it indefinitely. Since Linux 5.3 the kernel itself creates `@u` linked into a per-user-namespace register keyring ([5.3 keyrings namespacing pull](https://kernsec.org/pipermail/linux-security-module-archive/2019-July/015066.html), [`look_up_user_keyrings`](https://github.com/torvalds/linux/blob/v6.12/security/keys/process_keys.c#L74-L169)). The register lives as long as the namespace, which for the initial namespace means until reboot. This comes from reading the source; it was not measured.
- **Persistent keyring after logout.** It outlives the UID record. Each `KEYCTL_GET_PERSISTENT` resets its expiry to `/proc/sys/kernel/keys/persistent_keyring_expiry`, default 259200 s, which only root can change ([keyrings(7)](https://man7.org/linux/man-pages/man7/keyrings.7.html), [persistent.c](https://github.com/torvalds/linux/blob/v6.12/security/keys/persistent.c#L13)).
- **Containers.** Docker's default seccomp profile blocks `add_key`, `keyctl` and `request_key` "to prevent containers from using the kernel keyring, which is not namespaced" ([Docker seccomp](https://docs.docker.com/engine/security/seccomp/)). Blocked calls fail with `EPERM`, the profile's default errno ([moby default.json](https://github.com/moby/profiles/blob/main/seccomp/default.json)). Podman's default profile allows `keyctl` but not `add_key` or `request_key`, which fail with `ENOSYS` ([containers/common seccomp.json](https://github.com/containers/common/blob/main/pkg/seccomp/seccomp.json)). Since 5.3 a process in another user namespace, such as a rootless container, has its own `@u` and persistent keyrings.
- **Reboot.** It empties every keyring: the facility is in memory only ([linux-keyutils-keyring-store](https://docs.rs/linux-keyutils-keyring-store/latest/linux_keyutils_keyring_store/)).

### The five questions

- **Locked store.** A missing kernel key gives `ENOKEY`, an expired one `EKEYEXPIRED` and a revoked one `EKEYREVOKED` ([keyrings(7)](https://man7.org/linux/man-pages/man7/keyrings.7.html), [keyctl(1)](https://man7.org/linux/man-pages/man1/keyctl.1.html)). Each comes back from one system call with no prompt, so a non-interactive call can map all three to `locked` at once. In an interactive call, lendk would prompt for the unlock factor itself and add the kernel key.
- **Daemon.** None. The kernel holds the store key.
- **Human's controls.**
  - Each kernel key carries one absolute expiry, set with `KEYCTL_SET_TIMEOUT` (`keyctl timeout KEY SECONDS`). Zero clears it ([kernel key retention docs](https://docs.kernel.org/security/keys/core.html)).
  - The kernel has no idle timer. A sliding timeout like `default-cache-ttl` means lendk re-arms the expiry on each use. A cap like `max-cache-ttl` needs lendk to record the unlock time, since a kernel key holds only one expiry.
  - Expired and revoked kernel keys linger for `gc_delay` (300 s by default) before garbage collection, and report their state meanwhile ([keyrings(7)](https://man7.org/linux/man-pages/man7/keyrings.7.html)).
  - The human flushes with `keyctl revoke`, `keyctl unlink`, `keyctl clear @u`, a lendk verb that does the same, or a reboot ([keyctl(1)](https://man7.org/linux/man-pages/man1/keyctl.1.html)).
  - Quotas allow a user 200 kernel keys and 20,000 payload bytes by default ([keyrings(7)](https://man7.org/linux/man-pages/man7/keyrings.7.html)).
- **Rust crates.**
  - [`linux-keyutils`](https://docs.rs/linux-keyutils/latest/linux_keyutils/) (0.2.5) wraps the raw system calls without libkeyutils. It covers `get_persistent`, `set_timeout`, `revoke`, `invalidate` and `set_perms`.
  - [`keyutils`](https://docs.rs/keyutils) (0.4.0, 2023) binds libkeyutils.
  - [`linux-keyutils-keyring-store`](https://docs.rs/linux-keyutils-keyring-store/latest/linux_keyutils_keyring_store/) is prior art for the [`keyring`](https://docs.rs/keyring/latest/keyring/) ecosystem. It keeps entries in the persistent keyring and links them into the session keyring on use.
- **Same-user reach.** A kernel key added without explicit permissions grants its possessor view, read, search, link and setattr, and other processes of the UID view only ([key.c](https://github.com/torvalds/linux/blob/v6.12/security/keys/key.c#L916-L927)). A process possesses `@u` through `KEY_SPEC_USER_KEYRING`, and the persistent keyring once it links it in. So any same-user process in the same user namespace reads a store key cached in either. `/proc/keys` also shows such a process the kernel key's description and remaining time, but not its payload ([keyrings(7)](https://man7.org/linux/man-pages/man7/keyrings.7.html)). This is the reach gpg-agent's cache has in 1.x: any same-user process can run `pass show`.

## macOS Keychain and LocalAuthentication

macOS has two keychain implementations ([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)):

- **The file-based keychain** uses per-item access control lists. The `security` command-line tool works with it.
- **The data protection keychain** is the only one that supports biometric protection and Secure Enclave keys. It grants access through keychain access groups taken from code signing entitlements. Those entitlements must be authorized by a provisioning profile embedded in an app-like bundle, which command-line tools lack. It works only in a user login context.

### File-based login keychain

- **Lifetime.** The system opens the login keychain at GUI login and closes it at GUI logout, and "logging in via SSH does not unlock the keychain" (Apple DTS, [forum thread 712005](https://developer.apple.com/forums/thread/712005)). An ssh login runs in a non-GUI per-session security context, which Apple's security server, `securityd`, manages ([TN2083](https://developer.apple.com/library/archive/technotes/tn2083/_index.html)).
- **Locked store.** Functions that need the keychain open show an Unlock Keychain dialog. With user interaction disabled through `SecKeychainSetUserInteractionAllowed(false)`, they "return immediately with an errSecInteractionRequired result" ([SecKeychainSetUserInteractionAllowed](https://developer.apple.com/documentation/security/seckeychainsetuserinteractionallowed(_:))).
  - `SecKeychainGetStatus` reports whether a keychain is open ([SecKeychainGetStatus](https://developer.apple.com/documentation/security/seckeychaingetstatus(_:_:))).
  - Both functions are deprecated since macOS 10.10 and still documented.
  - Through the SecItem API, `kSecUseAuthenticationUIFail` makes a call that needs user authentication return `errSecInteractionNotAllowed` ([kSecUseAuthenticationUIFail](https://developer.apple.com/documentation/security/ksecuseauthenticationuifail)). Apple deprecates it in favor of `LAContext.interactionNotAllowed`.
  - Apple does not document whether that flag also suppresses the file-based keychain's unlock dialog, which SecItem reaches through a shim ([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)).
- **Daemon.** `securityd`, Apple's. lendk runs none.
- **Human's controls.**
  - Each keychain can close when the Mac sleeps and after an idle interval ([SecKeychainSetSettings](https://developer.apple.com/documentation/security/seckeychainsetsettings(_:_:)); `security set-keychain-settings -l -u -t SECONDS`).
  - `security lock-keychain` closes it at once.
  - GUI logout closes it.
- **Same-user reach.** An item's ACL lists the apps trusted for each operation. Any other app gets a prompt where the human picks Deny, Allow or Always Allow ([Access Control Lists](https://developer.apple.com/documentation/security/access-control-lists)). A same-user process that runs lendk itself acts as lendk.

### Data protection keychain with access control

- **Flags.** Access control flags require biometry or the passcode before each use of an item: `userPresence`, `biometryAny`, `biometryCurrentSet`, `devicePasscode`, and `applicationPassword` for an item-specific password ([SecAccessControlCreateFlags](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags), [Restricting keychain item accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility)).
- **Reuse.** An `LAContext` evaluates the policy. `touchIDAuthenticationAllowableReuseDuration` skips a prompt only "if the user unlocks the device using Touch ID within the specified time interval", up to a system maximum ([touchIDAuthenticationAllowableReuseDuration](https://developer.apple.com/documentation/localauthentication/lacontext/touchidauthenticationallowablereuseduration)). A context belongs to one process, so a fresh lendk process authenticates again. This mechanism gates each call; it does not keep the store unlocked between calls.
- **Locked store.** With `interactionNotAllowed` set, evaluation fails instead of prompting ([interactionNotAllowed](https://developer.apple.com/documentation/localauthentication/lacontext/interactionnotallowed)), and the item read returns `errSecInteractionNotAllowed`.
- **Packaging.** A lendk binary needs an entitlement that a provisioning profile authorizes, and an app-like bundle to embed the profile, to use this keychain at all ([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)). A lendk release for macOS would carry that signing and bundle.
- **Over ssh.** Apple documents no Touch ID path for a non-GUI ssh session. This survey did not test one.

### Rust crates for the Keychain

- [`security-framework`](https://docs.rs/security-framework/latest/security_framework/passwords/index.html) (3.7.0) covers generic passwords, `SecAccessControl` with flags, and `use_protected_keychain` for the data protection keychain.
- [`objc2-local-authentication`](https://docs.rs/objc2-local-authentication) (0.3.2) binds `LAContext`.
- [`apple-native-keyring-store`](https://docs.rs/apple-native-keyring-store) serves the `keyring` ecosystem.

## Secure Enclave and YubiKey through age plugins

An age plugin is a short-lived binary that the age client starts for each operation. It talks to the client over a pipe protocol in which it can show a message (`msg`), ask for confirmation (`confirm`) or ask for a PIN (`request-secret`). A client with no UI answers `fail` ([age plugin spec](https://github.com/C2SP/C2SP/blob/main/age-plugin.md)). The spec's own answer to caching is a daemon: the expected design is "a short-lifetime plugin binary ... which ... connects to (or starts, if not already running) a long-lifetime" process. The Rust [`age`](https://docs.rs/age/latest/age/) crate (0.12.1) runs plugins as a client, and [`age-plugin`](https://docs.rs/age-plugin) (0.7.0) writes them.

### Secure Enclave: age-plugin-se

- **Platform.** It needs macOS 14 and a Secure Enclave to decrypt ([age-plugin-se](https://github.com/remko/age-plugin-se)). Secure Enclave keys are P-256 only and never leave the enclave ([Protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave)).
- **Key storage.** The plugin creates a CryptoKit `SecureEnclave.P256.KeyAgreement.PrivateKey` and stores its `dataRepresentation` in the identity file. It uses no keychain, so it needs no provisioning profile. The key's protection class is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Its access control is one of `none`, `passcode`, `any-biometry`, `any-biometry-or-passcode` (the default), `any-biometry-and-passcode`, `current-biometry` or `current-biometry-and-passcode` ([Plugin.swift](https://github.com/remko/age-plugin-se/blob/main/Sources/Plugin.swift#L29-L53)).
- **Per-call authentication.** The plugin opens one `LAContext` per process and never sets a reuse duration or `interactionNotAllowed` ([Crypto.swift](https://github.com/remko/age-plugin-se/blob/main/Sources/Crypto.swift#L81-L98)). A biometric identity therefore prompts on every call. A `none` identity never prompts, so it is usable whenever the protection class allows.
- **Locked store.** The Touch ID dialog comes from the plugin, not through the protocol. A non-interactive call can only wait for it or stop the plugin; `LENDK_TIMEOUT` bounds that wait. A `none` identity has no locked state.
- **Daemon.** None of lendk's.
- **Human's controls.** The access control is fixed when the Secure Enclave key is generated.
- **Same-user reach.** With `none`, any same-user process that holds the identity file and runs the plugin decrypts.
- **Rust.** CryptoKit's Secure Enclave types have a Swift interface only ([CryptoKit](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement/privatekey)). A Rust lendk reaches them through the plugin binary or a Swift shim.

### YubiKey PIV: age-plugin-yubikey

- **Platform.** On Linux it needs the `pcscd` service ([age-plugin-yubikey](https://github.com/str4d/age-plugin-yubikey)), a system daemon that systemd starts on demand ([pcscd auto start using systemd](https://blog.apdu.fr/posts/2011/11/pcscd-auto-start-using-systemd)). On macOS it uses the system's own PC/SC.
- **Policies.**
  - The PIN policy is `never`, `once` (once per session) or `always`.
  - The touch policy is `never`, `always` or `cached`, where `cached` asks for a touch if more than 15 s passed since the last one ([Yubico PIN and touch policies](https://docs.yubico.com/yesdk/users-manual/application-piv/pin-touch-policies.html)).
  - The plugin generates keys with PIN `once` and touch `always` by default ([builder.rs](https://github.com/str4d/age-plugin-yubikey/blob/main/src/builder.rs#L19-L20)).
- **What holds the unlock.** The `once` PIN state lives in the token's PIV applet. The plugin avoids resetting the token, so the state can pass from one process to the next on YubiKey 5 ([README](https://github.com/str4d/age-plugin-yubikey#agent-support), [releases](https://github.com/str4d/age-plugin-yubikey/releases)). Unplugging the token or using another applet such as FIDO2 ends it.
- **Seconds, not minutes.** pcsc-lite powers off a card unused for 5 s (`PCSCLITE_POWER_OFF_GRACE_PERIOD`, [Rousseau 2010](https://blog.apdu.fr/posts/2010/10/card-auto-power-on-and-off/)), and `pcscd --auto-exit` quits 60 s after its last client ([pcscd(8)](https://manpages.debian.org/testing/pcscd/pcscd.8.en.html)). Users report the PIN cache lasting 5 to 10 s on macOS 14 and on NixOS, and on NixOS traced it to that power-off ([age-plugin-yubikey#198](https://github.com/str4d/age-plugin-yubikey/issues/198)).
- **Locked store.**
  - The plugin asks the client for the PIN with `request-secret`. A non-interactive call answers `fail` and ends at once.
  - A touch blocks inside the token until the human touches it; `LENDK_TIMEOUT` bounds that wait.
  - The slot's PIN and touch policies are readable as metadata on YubiKey 5.3 and later ([yubico-piv-tool release notes](https://developers.yubico.com/yubico-piv-tool/Release_Notes.html)), so a call can tell beforehand that a touch is required.
- **Over ssh on Linux.** Where pcsc-lite is built with polkit, its default policy grants access only to active local sessions, and an ssh login gets `SCardEstablishContext: Access denied` until root adds a rule ([pcsc-lite and polkit](https://blog.apdu.fr/posts/2023/11/pcsc-lite-and-polkit), [README.polkit](https://github.com/LudovicRousseau/PCSC/blob/master/doc/README.polkit)).
- **Daemon.** `pcscd` on Linux, a system service; none of lendk's.
- **Human's controls.** Unplug the token. The policies are fixed when the PIV key is generated.
- **Same-user reach.** While the PIN is cached, any same-user process with PC/SC access can decrypt, subject to the touch policy.
- **Rust.** The plugin itself is Rust, and the [`yubikey`](https://docs.rs/yubikey) crate (0.8.0) drives PIV in-process over PC/SC.

## FIDO2 hmac-secret

- **Mechanism.** The `hmac-secret` extension keeps two random values per credential on the token: one used when user verification happened and one when it did not. The token returns HMAC-SHA-256 of a 32-byte salt sent by the host ([CTAP 2.2, section 12.7](https://fidoalliance.org/specs/fido-v2.2-rd-20241003/fido-client-to-authenticator-protocol-v2.2-rd-20241003.html)). The host keeps the salt and the credential ID, and the token keeps the secret part. A store key derived from the output therefore needs the token on every derivation. Verification also changes the output, so a store key enrolled with user verification needs it, by PIN or fingerprint, on every derivation.
- **Presence.** `getAssertion` requires user presence unless the host sends `up` = `false`. The spec uses that option for pre-flight checks, and tokens differ in whether they then return `hmac-secret` output. systemd-cryptenroll's `--fido2-with-user-presence=no` relies on tokens that do, "without effect if the security token does not support" it ([systemd-cryptenroll(1)](https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html)).
- **PIN state.** A PIN yields a `pinUvAuthToken` that the host process holds. The token voids it after a maximum usage period, by default at most 10 minutes, and makes a fresh one at each power-on (CTAP 2.2, sections 6.5.2.1 and 6.5.6). Reusing it in the next call would need somewhere to keep it between calls.
- **Locked store.** Without the token, the call fails at once. With it, an assertion that needs presence waits for a touch until the token times out or the host cancels it; `LENDK_TIMEOUT` bounds the wait.
- **Linux access.**
  - systemd tags FIDO tokens `uaccess` ([70-uaccess.rules](https://github.com/systemd/systemd/blob/main/rules.d/70-uaccess.rules.in)). That grants an ACL on the hidraw node to the user with the active session on the seat ([sd-login(3)](https://www.freedesktop.org/software/systemd/man/latest/sd-login.html)).
  - A user reached only over ssh, with no active local session, has no access until root adds a rule ([libfido2 README](https://github.com/Yubico/libfido2)).
  - macOS needs no rule; libfido2 runs on both.
- **Daemon.** None.
- **Human's controls.** Unplug the token, and choose presence and PIN at enrollment.
- **Same-user reach.** Any same-user process that can open the device and holds the salt and credential ID derives the same output, subject to touch.
- **Rust.** [`ctap-hid-fido2`](https://docs.rs/ctap-hid-fido2) (3.6.0, `HmacSecret` in `get_assertion`), Mozilla's [`authenticator`](https://docs.rs/authenticator) (0.5.0, `hmac-secret` and PRF), and [`fido2-rs`](https://docs.rs/fido2-rs) (0.6.0, libfido2 bindings).

## ssh-agent

- **Mechanism.** ssh-agent signs but never decrypts, and age does not support keys "accessed via ssh-agent" ([age(1)](https://filippo.io/age/age.1)). A store key can still be derived from a signature over a fixed challenge, since Ed25519 signatures are deterministic ([RFC 8032](https://www.rfc-editor.org/rfc/rfc8032)). [age-plugin-sshagent](https://github.com/eszio/age-plugin-sshagent), a third-party plugin from 2026, does this and accepts only `ssh-ed25519` keys. FIDO `sk-` signatures include a counter, so they do not repeat.
- **Locked store.** With `SSH_AUTH_SOCK` unset, or the ssh key not loaded, the signature request fails at once; [ssh-add(1)](https://man.openbsd.org/ssh-add.1) exits 2 when it cannot reach ssh-agent. An ssh key added with `ssh-add -c` makes ssh-agent ask `ssh-askpass` for confirmation, and the call waits on it.
- **Daemon.** ssh-agent itself, OpenSSH's daemon.
- **Human's controls.**
  - `ssh-agent -t` and `ssh-add -t` set an ssh key's maximum lifetime; the default is forever.
  - `ssh-add -d` and `-D` remove ssh keys, and `SIGUSR1` makes ssh-agent delete all of them.
  - `ssh-add -x` puts ssh-agent behind a password and `-X` takes it off ([ssh-agent(1)](https://man.openbsd.org/ssh-agent.1), [ssh-add(1)](https://man.openbsd.org/ssh-add.1)).
- **Same-user reach.** The socket "is accessible only to the current user, but is easily abused by root or another instance of the same user" ([ssh-agent(1)](https://man.openbsd.org/ssh-agent.1)). Any process that reaches it, a forwarded one on another host included, can request the same signature and derive the store key ([age-plugin-sshagent README](https://github.com/eszio/age-plugin-sshagent)).
- **Rust.** [`ssh-agent-client-rs`](https://docs.rs/ssh-agent-client-rs) (1.1.4) and [`ssh-agent-lib`](https://docs.rs/ssh-agent-lib) (0.6.0).

## A key file with mode 0600

- **Mechanism.** The store key sits in a file only its owner can read. No unlock happens, so the store is never locked.
- **Placement.** In `$XDG_RUNTIME_DIR`, the file lives from the user's first login to the last logout and never survives a reboot ([XDG Base Directory spec](https://specifications.freedesktop.org/basedir-spec/latest/)). pam_systemd mounts `/run/user/$UID` as tmpfs and removes it when the last session ends ([pam_systemd(8)](https://www.freedesktop.org/software/systemd/man/latest/pam_systemd.html)). tmpfs pages can move to swap ([tmpfs(5)](https://man7.org/linux/man-pages/man5/tmpfs.5.html)). This survey found no macOS directory with that lifetime.
- **Locked store.** None while the file exists. Without it, the call fails at once.
- **Daemon.** None.
- **Human's controls.** Delete the file. In the runtime directory, the last logout deletes it too, unless lingering keeps the user's session alive.
- **Same-user reach.** It reads the file; root and backups do too.
- **Rust.** The standard library.
- **ADR tension.** [ADR 0006](../adr/0006-values-only-in-memory.md) keeps values out of files. A store key in a file is not a value, but it decrypts every value.

## Comparison

| Mechanism | Linux | macOS | Holds the unlock between calls | Non-interactive call on a locked store | Daemon, and whose | Human's lifetime and flush controls | Same-user process | Rust crates |
|---|---|---|---|---|---|---|---|---|
| Kernel session keyring | Yes | No | Within one login; tmux panes lose it when the starting login ends | `ENOKEY`, `EKEYEXPIRED` or `EKEYREVOKED` at once | None | Per-key expiry; revoke or unlink; logout revokes | Reads it within that login | `linux-keyutils`, `keyutils` |
| Kernel user keyring | Yes | No | Yes, across logins until reboot (Linux 5.3 and later) | Same | None | Per-key expiry; revoke, unlink or clear; reboot | Reads it | Same |
| Kernel persistent keyring | Yes | No | Yes, across logouts until it expires (3 days after the last request by default) | Same | None | Per-key expiry; keyring expiry is root's sysctl | Reads it | Same |
| Login keychain item (file-based) | No | Yes | While the login keychain is open: GUI login to logout, sleep or idle close | `errSecInteractionRequired` with interaction disabled | `securityd`, Apple's | Close on sleep, idle interval, `security lock-keychain` | Gets a prompt unless the ACL trusts it; runs lendk to act as lendk | `security-framework` |
| Data protection keychain with Touch ID | No | With a provisioning profile | No: each process authenticates | `errSecInteractionNotAllowed` with `interactionNotAllowed` | Apple's | Per-item access control | Needs the access group entitlement | `security-framework`, `objc2-local-authentication` |
| Secure Enclave, age-plugin-se | No | macOS 14 and later | No with biometry or passcode; `none` never asks | Touch ID dialog, no switch to refuse it | None of lendk's | Fixed at key generation | With `none`, decrypts by running the plugin | `age` client; Swift for CryptoKit |
| YubiKey PIV, age-plugin-yubikey | Yes, with `pcscd` | Yes | PIN for seconds (5 s card power-off); touch 15 s with `cached` | PIN request answered `fail` at once; touch blocks | `pcscd` on Linux, a system service; macOS's own PC/SC stack | Unplug; policies fixed at key generation | Decrypts while the PIN is cached, within the touch policy | `age`, `age-plugin`, `yubikey` |
| FIDO2 hmac-secret | Yes, active local session | Yes | No: presence per assertion unless the token accepts `up` = `false` | Fails without the token; waits for a touch | None | Unplug; enrollment options | Derives it if it can open the device | `ctap-hid-fido2`, `authenticator`, `fido2-rs` |
| ssh-agent signature | Yes | Yes | Yes, while ssh-agent holds the Ed25519 key | Fails at once without the socket or the ssh key; waits with `ssh-add -c` | ssh-agent, OpenSSH's | `-t` lifetime, `-d`, `-D`, `-x`, `SIGUSR1` | Derives it through the socket, forwarded hosts too | `ssh-agent-client-rs`, `ssh-agent-lib` |
| Key file, mode 0600 | Yes | Yes | Always: never locked | Never locked | None | Delete the file; runtime directory clears at last logout | Reads the file | Standard library |

## Facts the grilling ticket needs

- **Caches and factors are separate roles.** The kernel keyring, the login keychain, ssh-agent and a key file hold an unlock between calls. A passphrase, a YubiKey, a FIDO2 token and the Secure Enclave produce one on demand but hold it for seconds at most. A factor that unlocks once per period needs one of the caches beside it.
- **ADR 0007's precondition.** On Linux the kernel keyring runs no daemon at all. On macOS the login keychain runs no lendk daemon, but its state lives in `securityd`, as 1.x's lives in gpg-agent. No single mechanism keeps the store unlocked on both platforms without someone's daemon, except a key file, which never locks.
- **ADR 0007's reasoning.** ADR 0007 rejects keeping values beyond a call because any same-user process could reach them. Any of the caches above keeps the store key beyond a call, and the store key yields every value. That is the reach gpg-agent's cache has in 1.x.
- **The docker gate.** `make check-docker` runs its containers with `docker run` and Docker's default seccomp profile (`Makefile`, `DOCKER_RUN`), which blocks `add_key` and `keyctl`. A suite that exercises a kernel keyring cache inside those images needs another seccomp profile or a host run.
- **Agents.** An agent that runs as the human's user reaches `@u` and the persistent keyring from any session, background jobs started outside the login session included. On macOS an agent in an ssh session finds the login keychain closed unless the human opened it there.

## Open questions

These were not verified and need a prototype:

- **`@u` lifetime.** Whether `@u` keeps a key after the user's last process exits on a 6.x kernel, as the 5.3 source implies. Test it on a throwaway VM, not on a developer's host.
- **Login keychain over ssh.** Whether an ssh session reads an item from a login keychain that the GUI session opened.
- **The SecItem flag.** Whether `kSecUseAuthenticationUIFail` or `interactionNotAllowed` suppresses the file-based keychain's Unlock Keychain dialog.
- **Touch ID over ssh.** What Touch ID does from an ssh session: a dialog on the console, or an error.
- **`WhenUnlocked` on macOS.** What a Secure Enclave key with protection `WhenUnlockedThisDeviceOnly` and access control `none` does while the screen is locked.
- **Silent assertions.** Which FIDO2 tokens return `hmac-secret` output for `up` = `false`.

Not surveyed: the Secret Service API (GNOME Keyring, KWallet), TPM 2.0 through age-plugin-tpm, and macOS `LARight` and `LASecret`.
