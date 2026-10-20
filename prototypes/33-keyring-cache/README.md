# PROTOTYPE for #33: the kernel user keyring as the identity cache

Throwaway code on the `prototype/keyring-cache` branch, which never merges. It answers [#33](https://github.com/v-bonilla/lendk/issues/33): does the kernel's user keyring hold the unlocked identity as [#23](https://github.com/v-bonilla/lendk/issues/23) expects? The answer, with the evidence for each claim, is the resolution comment on #33. This directory keeps the code and the raw output, so every check can run again.

## Verdict

`@u` holds the identity as #23 expects: across logins, after the user's last process exits, until reboot. One correction applies. A key with possessor-only permissions reads back only in a process that possesses `@u`, and a tmux pane after its login ends, a background job outliving its login, cron and `sudo` do not. lendk links `@u` into its own thread keyring before each keyring call, and then every context reads the key. A sandbox with its own user namespace, such as Claude Code's on Linux, sees an empty `@u`.

## What is here

- `keyprobe/`: a Rust binary that uses the kernel keyring as #23's identity cache would, through raw system calls and the `libc` crate only, as #27 allows. It prints `key=value` lines and never prints a payload, which is a stand-in marker. Its header lists the commands. `get ... possess` and `lock ... possess` link `@u` into the thread keyring first; `put ... staged` builds the key in the thread keyring and moves it into the cache with `KEYCTL_MOVE`.
- `agetime/`: a Rust binary that writes an age scrypt file holding a fresh X25519 identity, as #24's `lendk setup` would, and times the `age` crate (`=0.12.1`) opening it under a work factor limit.
- `vm/`: `up.sh` boots an Ubuntu 24.04 cloud image under QEMU inside a container, with users `ops` (sudo) and `alice` (the subject). QEMU runs with TCG, since the development host has no `/dev/kvm`, so the VM's CPU is about 24 times slower than the host's.
- `claims/`: one script per claim of #33, run from the host. Each `as_alice` call is a fresh ssh login with its own session keyring. `suite-sim.sh` and `perl-join.sh` stand in for a 2.0 suite run under the `LENDK_TEST_CACHE` hook. `claim6-host.sh` times the identity file on the host, where no keyring call happens.
- `results/`: the output each script printed, on 2026-10-19 and 2026-10-20.
- `../../.github/workflows/keyring-probe.yml`: the runner's half of claim 5, on each push to this branch.

## Running it

Never run `keyprobe put` or `lock` on a developer's machine: `@u` is shared by every process of the user.

```sh
S=/path/to/scratch   # holds noble.img (the Ubuntu 24.04 cloud image) and an ssh key pair id_proto33
docker build -t lendk-proto33-qemu - <<'EOF'
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils cloud-image-utils openssh-client ca-certificates
EOF
vm/up.sh "$S"        # cloud-init takes about 100 minutes under TCG
for c in keyprobe agetime; do
	(cd $c && CARGO_TARGET_DIR="$S/target" RUSTFLAGS='-C target-feature=+crt-static' \
		cargo build --release --target x86_64-unknown-linux-gnu)
done
# install both binaries in the VM's /usr/local/bin, claims/ and claims/seccomp-profile.sh's
# output (as profile.json) in /tmp/proto33, alice's Node 22 and srt, and the lendk-test:ubuntu image
claims/claim1.sh     # and so on, through claim6.sh; claim6-host.sh runs on the host
```
