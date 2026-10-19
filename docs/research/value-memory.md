# Memory hygiene for values in a Rust lendk

Research for [#20][t20], a ticket of the [lendk 2.0 map][map]. The question: what can a Rust process do to keep values out of swap, core dumps and freed memory on Linux and macOS, and what does each measure buy against the threats [ADR 0008][adr8] keeps in scope, given that lendk execs the target within milliseconds of the decrypt? This file states facts and makes no decision; [#26][t26] decides. Every source was read on 2026-10-19.

## Scope

- The window runs from a call's first decrypt to the `execve` of the target, or to exit when the call fails. The map gives the store one file per key, so a call decrypts only the keys its target gets.
- The window lasts milliseconds only while nothing waits inside it. A passphrase prompt between two decrypts stretches it to human time.
- [ADR 0006][adr6] says a value reaches the target's environment and nothing else: no output, file, argv, or environment of another process. [ADR 0008][adr8] places same-user processes, the target and its descendants, and root outside the model.
- Inside that model, a memory measure matters where the kernel or a crash handler copies a value from lendk's memory into a file: a swap device, a hibernation image, a core file, a crash journal entry. Reading lendk's live memory, through ptrace or `/proc/PID/mem`, takes the same user or root, both outside the model.

## What exec and exit already do

- `execve` replaces the program "with newly initialized stack, heap, and (initialized and uninitialized) data segments". Memory mappings and memory locks are not preserved, and the dumpable attribute goes back to 1 unless the new program is set-user-ID, set-group-ID or carries capabilities ([execve(2)][execve]).
- Rust's `CommandExt::exec` runs no destructors on success, and "the `execvp` syscall independently guarantees that all memory is freed" ([std docs][std-exec]). `std::process::exit` and `std::process::abort` run no destructors either ([exit][std-exit], [abort][std-abort]).
- Linux zero-fills an anonymous page before it maps the page into a process ([mm/memory.c, `alloc_anon_folio`][k-anon]), so a page lendk frees at exec or exit never reaches another process with its bytes. A freed page keeps its bytes in RAM until reuse, where only the kernel, root or physical access reach it.
- `init_on_free`, which zeroes pages and heap objects as they are freed ([kernel-parameters][k-params]), is off by default on Debian 13 (`/boot/config-6.12.111+deb13-amd64` on this host), Ubuntu 24.04 ([6.8.0-147 headers package][ubuntu-deb]) and Fedora ([f42][fedora-f42], [rawhide][fedora-rawhide]). `init_on_alloc` is on in all three.
- The kernel copies the `envp` strings into the new program ([execve(2)][execve]). For the target's lifetime its `/proc/PID/environ` shows them behind a `PTRACE_MODE_READ_FSCREDS` check, which a same-user process passes ([proc_pid_environ(5)][environ5], [ptrace(2)][ptrace]). ADR 0008 accepts this.
- `/proc/PID/environ` holds "the initial environment that was set when the currently executing program was started" and does not reflect later `putenv` changes ([proc_pid_environ(5)][environ5]). lendk's own file therefore shows the caller's environment, which under a nested shim already holds the outer command's values ([ADR 0007][adr7]).
- On macOS, a process of the same uid, or root, reads another process's argv and environment through the `KERN_PROCARGS2` sysctl. XNU omits the environment only for a target flagged `CS_RESTRICT`, unless SIP is off or the caller holds a private entitlement ([kern_sysctl.c][xnu-procargs], [kern_sysctl.c uid check][xnu-procargs-uid]). `CS_RESTRICT` is a different flag from the hardened runtime's `CS_RUNTIME` ([kern_cs.c][xnu-csrestricted]).

## Copies a Rust process makes

- `zeroize` 1.9.1 guarantees "the zeroing operation can't be 'optimized away' by the compiler", through `write_volatile` and memory fences. Its `Vec`, `String` and `CString` impls clear the whole capacity "but cannot guarantee copies of the data were not previously made by buffer reallocation". It provides no `mlock` or `mprotect`, clears no registers, and gives no guarantee against microarchitectural leaks ([docs][zeroize]).
- `secrecy` 0.10.3 wraps a value in `SecretBox` or `SecretString`, makes access explicit through `ExposeSecret`, keeps the value out of `Debug` output, and zeroizes it on drop through `zeroize`. It "does not provide more advanced memory protection mechanisms e.g. ones based on `mlock(2)` / `mprotect(2)`" and points to the `secrets` crate ([docs][secrecy]).
- Zeroize-on-drop runs only when a value is dropped. A successful exec, `exit`, `abort`, a panic in a `panic = "abort"` build, and a fatal signal run no destructors ([exec][std-exec], [exit][std-exit], [abort][std-abort]).
- `std::process::Command` keeps its own copies of each value. `env` stores `value.to_owned()`, the capture at spawn or exec clones the whole map, and `construct_envp` builds a third `KEY=VALUE` buffer per variable ([env.rs][std-env-src], [common.rs][std-envp-src], Rust 1.90.0). None of them is zeroed. A successful exec discards them; a failed exec returns with them still on the heap.
- `execve` called directly takes the `envp` pointers the caller builds ([execve(2)][execve]), so every copy of a value before the kernel's own is one that lendk allocates and can lock or zero.
- A decrypt library's internal buffers are beyond lendk's reach unless the library writes into a buffer lendk supplies. Which library that is waits on the store format.

## Swap

- `mlock` keeps pages resident, "preventing that memory from being paged to the swap area". An unprivileged process may lock up to its soft `RLIMIT_MEMLOCK`. Locks are page-granular, are not inherited by `fork`, and are removed by `execve` ([mlock(2)][mlock], [getrlimit(2)][getrlimit]).
- `mlockall(MCL_CURRENT | MCL_FUTURE)` locks every mapping, the binary and its libraries included, against the same limit. With `MCL_FUTURE`, a later `mmap` or `malloc` may fail, and stack growth may end in `SIGSEGV` ([mlock(2)][mlock]).
- Linux v6.12 sets the default `MLOCK_LIMIT` to 8 MiB ([resource.h][k-mlocklimit]), up from 64 KiB ([LWN][lwn-memlock]). systemd's `DefaultLimitMEMLOCK=` defaults to 8M ([systemd-system.conf(5)][sd-system-conf]). This Debian 13 host, with systemd 257, shows 8388608 bytes in `/proc/self/limits`. With one locked 4 KiB page per value, as `memsec`'s allocator lays them out, 8 MiB covers 2048 values.
- `region` 4.0.1 `lock` wraps `mlock` and returns a `LockGuard` that unlocks on drop. It keeps pages in RAM "except for specials cases, such as hibernation and memory starvation" ([docs][region-lock]).
- `memsec` 0.7.0 `mlock` also calls `madvise(MADV_DONTDUMP)` on Linux, `MADV_NOCORE` on FreeBSD and DragonFly, and no dump exclusion on macOS. Its `munlock` zeroes the range first ([mlock.rs][memsec-mlock]). Its `malloc` puts no-access guard pages around each allocation, adds a canary, and calls `mlock` without checking the result, so an allocation over the limit succeeds unlocked ([alloc/mod.rs][memsec-alloc]). Its last release dates from 2024-06.
- `secrets` 1.3.0 gives guarded, locked allocations that are zeroed when freed, through libsodium's C functions. In release builds it sets `RLIMIT_CORE` soft and hard to 0 when it first initializes ([docs][secrets], [sodium.rs][secrets-src]).
- Fedora 33 made swap on zram, a compressed RAM device, the default, and dropped disk swap from the installer ([Changes/SwapOnZRAM][fedora-zram]). macOS keeps "encrypted swap files" on its VM volume ([Apple Platform Security][apple-swap]).
- macOS `mlock` caps a process at "the minimum of a system-wide 'wired pages' limit and the per-process RLIMIT_MEMLOCK resource limit" and fails with `EAGAIN` beyond it ([mlock(2), macOS][mac-mlock]). XNU starts every resource limit at infinity except `NOFILE`, `NPROC`, `STACK`, `DATA` and `CORE` ([bsd_init.c][xnu-limits]), so `RLIMIT_MEMLOCK` starts unlimited. What launchd sets was not checked on a running Mac.

What it buys: a locked page cannot reach swap during the window, and for a swap-out without the lock, the kernel must reclaim that very page within those milliseconds. Only locked pages are covered. `Command`'s copies, a library's buffers and the stack stay swappable unless `mlockall` covers everything.

## Hibernation

- Suspend to disk saves "a copy of the system's RAM to disk, regardless of memory locks" ([mlock(2)][mlock]).
- Linux refuses to hibernate while any `memfd_secret` area exists, or under kernel lockdown ([hibernate.c][k-hibernate], [memfd_secret(2)][memfdsecret]). On Debian, Secure Boot turns on lockdown, which disables hibernation and resume ([Debian SecureBoot][debian-sb]).

What it buys: for a value to reach the image, a hibernation must start inside the window.

## memfd_secret (Linux only)

- The call exists since Linux 5.14. "Before Linux 6.5, memfd_secret() was disabled by default" behind the `secretmem.enable` boot parameter ([memfd_secret(2)][memfdsecret], [Linux 6.5][kn65]). Linux v6.12 defaults it on ([secretmem.c][k-secretmem-enable]). The parameter's sysfs file is mode 0400, readable by root only, so a process learns availability from the call: `ENOSYS` when it is off.
- `CONFIG_SECRETMEM=y` on Debian 13 (6.12, this host's `/boot` config), Ubuntu 24.04 (6.8.0-147, the GA kernel; HWE kernels not checked, [headers package][ubuntu-deb]) and Fedora ([f42][fedora-f42], [rawhide][fedora-rawhide], from kernel-ark's [common config][kernel-ark]). All three run kernels past 6.5, so the call works by default.
- glibc has no wrapper, so the call goes through `syscall(2)`. The pages leave the kernel's direct map and are "disallowed in get_user_pages", and the man page still gives "no 100% guarantee" that the kernel cannot reach them ([memfd_secret(2)][memfdsecret]).
- The mapping must be `MAP_SHARED`. The kernel marks it `VM_LOCKED | VM_DONTDUMP` and checks it against `RLIMIT_MEMLOCK` ([secretmem.c][k-secretmem-mmap]), so its pages stay out of swap and out of core dumps.
- The descriptor is inherited by `fork` and kept across `execve` unless `FD_CLOEXEC` is set ([memfd_secret(2)][memfdsecret]).
- Docker's default seccomp profile allows `memfd_secret`, `mlock`, `mlockall`, `madvise`, `prctl` and `setrlimit` ([moby/profiles][moby-seccomp]).
- `memsec` 0.7.0 offers `alloc_memfd_secret`, its guarded allocator backed by this call, which returns `None` when the call fails ([linux.rs][memsec-memfd], [README][memsec-readme]).

What it buys: inside the window, the bytes in the area stay out of swap, core files and the hibernation image. Only bytes written into the area are covered: the decrypt output must land there, and any copy made elsewhere is unprotected. Whether `execve` reads `envp` strings that sit inside the area was not tested.

## Core dumps and crash records

- A core comes from a signal whose default action is Core: `SIGABRT`, `SIGSEGV`, `SIGBUS` and `SIGQUIT` among them ([signal(7)][signal7]). Rust's `abort`, and a panic in a `panic = "abort"` build, end in `SIGABRT` ([abort][std-abort]). `SIGQUIT` comes from the terminal's quit key, so a human can raise it while lendk waits at a prompt.
- Under the kernel's default `core_pattern`, the file is `core` in the process's current directory ([core(5)][core5]). lendk's current directory is the caller's, often a repository.
- `RLIMIT_CORE` 0 stops the core file, but "RLIMIT_CORE will be ignored if the system is configured to pipe core dumps to a program" ([core(5)][core5]). An unprivileged process may set its soft limit anywhere up to the hard limit, and may lower the hard limit irreversibly. Limits pass to `fork` children and survive `execve` ([getrlimit(2)][getrlimit]). lendk can lower its soft limit and raise it again before exec. `secrets` lowers both to 0, so the target would inherit 0:0.
- systemd-coredump handles the core where `core_pattern` pipes to it; systemd's `50-coredump.conf` sets that up ([systemd-coredump(8)][sd-coredump]). Below a page of `RLIMIT_CORE`, v257 skips the core ([coredump.c][sd-src-rlimit]) but still logs a journal entry, "terminated abnormally without generating a coredump" ([coredump.c][sd-src-submit]). The entry carries `COREDUMP_ENVIRON`, the contents of `/proc/PID/environ` ([coredump.c][sd-src-environ], [systemd-coredump(8)][sd-coredump]). It is written as the crashed process's user, so that user can read it ([coredump.c][sd-src-privs]).
- For lendk, that entry holds the caller's environment, which under a nested shim includes the outer command's values. Values that lendk decrypted and holds only in memory are not in it.
- Apport, when started, points `core_pattern` at itself and sets `suid_dumpable` to 2 ([apport][apport-start]). For an executable that belongs to no package, it logs "executable does not belong to a package, ignoring" and writes only a user core that honors the limit ([apport][apport-unpackaged]). For a packaged one, it writes a `.crash` report holding the core image. Its `ProcEnviron` field keeps "only some standard variables" ([report.py][apport-environ]).
- `prctl(PR_SET_DUMPABLE, 0)` stops core dumps and `PTRACE_ATTACH`, and makes the `/proc/PID` files `root:root` ([PR_SET_DUMPABLE(2const)][dumpable], [proc_pid(5)][procpid5]). In v6.12, the kernel checks the flag before it reads `core_pattern`, so no pipe helper runs and no crash journal entry is written ([fs/coredump.c][k-coredump]). `execve` sets the flag back to 1 for an ordinary target ([execve(2)][execve]), so the target keeps its usual crash behavior.
- `madvise(MADV_DONTDUMP)` leaves a page-aligned range out of a core dump, over `/proc/PID/coredump_filter` ([madvise(2)][madvise]). It does not touch the journal's environment record.
- systemd's PID 1 sets `RLIMIT_CORE` to infinity for its children ([systemd-system.conf(5)][sd-system-conf]). This Debian 13 host shows a soft limit of 0 and an unlimited hard limit in `/proc/self/limits`. The limits lendk starts with are whatever its caller has.
- The target's own crash is another matter. After exec, the target's environment holds the values, its dumpable flag is 1 again, and systemd-coredump logs `COREDUMP_ENVIRON` whatever the core limit. Nothing lendk sets before exec stops that record. ADR 0008 places the target outside the model.
- On macOS, XNU starts `RLIMIT_CORE` at soft 0 and hard infinity ([bsd_init.c][xnu-limits], [vmparam.h][xnu-dflcsiz]). It writes a core only when the mapped size fits under `RLIMIT_CORE` and the MAC policy allows it, by default to `/cores/core.PID` ([kern_core.c eligibility][xnu-core], [kern_core.c limit][xnu-core-limit]). Apple DTS lists the steps for a core: `ulimit -c unlimited`, a writable `/cores`, and the `com.apple.security.get-task-allow` entitlement in the binary's signature ([Apple forums][apple-dts-core]).

What it buys: `PR_SET_DUMPABLE(0)` keeps a crash in the window from writing either the core or the journal's environment record. `RLIMIT_CORE` 0 stops the core file only. `MADV_DONTDUMP` and `memfd_secret` keep chosen ranges out of a core that is written.

## Same-user readers (outside ADR 0008)

- On Linux, reading `/proc/PID/mem` takes a `PTRACE_MODE_ATTACH_FSCREDS` check ([proc_pid_mem(5)][mem5]), and the check denies a non-dumpable target to a caller without `CAP_SYS_PTRACE` ([ptrace(2)][ptrace]). Yama's `ptrace_scope` 1 limits attaching to the caller's descendants. The man page names 1 the default ([ptrace(2)][ptrace]); this Debian 13 host reads 0.
- On macOS, `PT_DENY_ATTACH` "sets a flag that denies future traces" ([ptrace(2), macOS][mac-ptrace]), and XNU then fails an attach with `EBUSY` ([mach_process.c][xnu-denyattach]). XNU copies the flag to the new image at exec ([kern_exec.c][xnu-exec]), so the target inherits it.
- A debugger cannot get the task port of a process without the `com.apple.security.get-task-allow` entitlement ([Debugging tool entitlement][apple-debugger], [Hardened Runtime][apple-hardened]).
- These measures narrow who reads lendk's memory during the window. ADR 0008's reasoning rests on `pass show` and `/proc/PID/environ` being open to same-user processes. Whether the 2.0 unlock model leaves an equal path is for the unlock research.

## Summary

| Measure | Linux | macOS | Keeps a value out of | Limits |
|---|---|---|---|---|
| exec itself | yes | yes | lendk's address space after the call | the target's environment stays, by design |
| `zeroize`, `secrecy` | yes | yes | buffers lendk owns, once dropped | realloc, `Command`, library copies; no drop on exec, exit, abort or signal |
| `execve` with lendk's own `envp` | yes | yes | `Command`'s three unzeroed copies | `unsafe` FFI |
| `mlock` (`region`, `memsec`) | yes, 8 MiB default | yes, wired-page cap | swap | not hibernation; locked pages only |
| `mlockall` | yes | not checked | swap, for every mapping | whole process against the limit; later allocations may fail |
| `memfd_secret` | 5.14, on by default since 6.5 | none | swap, core, hibernation image, kernel direct map | bytes in the area only; `ENOSYS` needs a fallback |
| `MADV_DONTDUMP` | yes | none in `memsec` | the core file, for that range | the journal's environment record stays |
| `RLIMIT_CORE` soft 0 | yes | yes | the core file | ignored by a pipe; systemd still logs the environment; the target inherits it unless restored |
| `PR_SET_DUMPABLE(0)` | yes | none | core, pipe helper, journal record; same-user `/proc` reads and ptrace | reset at exec |
| `PT_DENY_ATTACH` | none | yes | same-user ptrace attach | the target inherits it |
| no `get-task-allow` | none | yes | same-user task port, and the core per Apple DTS | signing |

Swap, hibernation, core files and the crash journal are files a value would reach, which ADR 0006 rules out. ptrace, `/proc/PID/mem` and task ports are same-user reads, which ADR 0008 places outside the model.

## Gaps

- No running Ubuntu, Fedora or macOS host was examined. Ubuntu's config came from its archive's headers package, because Launchpad's annotations file returned 403 to curl, to a browser user agent and to the Parallel fetcher. Fedora's came from dist-git and kernel-ark.
- Ubuntu's HWE kernels, each distribution's default soft `RLIMIT_CORE`, macOS's `RLIMIT_MEMLOCK` as launchd sets it, and macOS hibernation were not surveyed.
- Whether `execve` can read `envp` strings from a `memfd_secret` area, and whether `/proc/PID/mem` reads of such an area fail, were not tested.

[t20]: https://github.com/v-bonilla/lendk/issues/20
[t26]: https://github.com/v-bonilla/lendk/issues/26
[map]: https://github.com/v-bonilla/lendk/issues/15
[adr6]: ../adr/0006-values-only-in-memory.md
[adr7]: ../adr/0007-no-daemon-no-value-cache.md
[adr8]: ../adr/0008-same-user-threats-out-of-scope.md
[execve]: https://man7.org/linux/man-pages/man2/execve.2.html
[environ5]: https://man7.org/linux/man-pages/man5/proc_pid_environ.5.html
[mem5]: https://man7.org/linux/man-pages/man5/proc_pid_mem.5.html
[procpid5]: https://man7.org/linux/man-pages/man5/proc_pid.5.html
[ptrace]: https://man7.org/linux/man-pages/man2/ptrace.2.html
[mlock]: https://man7.org/linux/man-pages/man2/mlock.2.html
[getrlimit]: https://man7.org/linux/man-pages/man2/getrlimit.2.html
[core5]: https://man7.org/linux/man-pages/man5/core.5.html
[signal7]: https://man7.org/linux/man-pages/man7/signal.7.html
[madvise]: https://man7.org/linux/man-pages/man2/madvise.2.html
[dumpable]: https://man7.org/linux/man-pages/man2/PR_SET_DUMPABLE.2const.html
[memfdsecret]: https://man7.org/linux/man-pages/man2/memfd_secret.2.html
[k-anon]: https://github.com/torvalds/linux/blob/v6.12/mm/memory.c#L4653-L4728
[k-params]: https://github.com/torvalds/linux/blob/v6.12/Documentation/admin-guide/kernel-parameters.txt#L2186-L2193
[k-mlocklimit]: https://github.com/torvalds/linux/blob/v6.12/include/uapi/linux/resource.h#L79
[k-coredump]: https://github.com/torvalds/linux/blob/v6.12/fs/coredump.c#L554-L558
[k-secretmem-enable]: https://github.com/torvalds/linux/blob/v6.12/mm/secretmem.c#L38-L41
[k-secretmem-mmap]: https://github.com/torvalds/linux/blob/v6.12/mm/secretmem.c#L125-L134
[k-hibernate]: https://github.com/torvalds/linux/blob/v6.12/kernel/power/hibernate.c#L92-L97
[kn65]: https://kernelnewbies.org/Linux_6.5
[lwn-memlock]: https://lwn.net/Articles/876288
[ubuntu-deb]: http://archive.ubuntu.com/ubuntu/pool/main/l/linux/linux-headers-6.8.0-147-generic_6.8.0-147.147_amd64.deb
[fedora-f42]: https://src.fedoraproject.org/rpms/kernel/raw/f42/f/kernel-x86_64-fedora.config
[fedora-rawhide]: https://src.fedoraproject.org/rpms/kernel/raw/rawhide/f/kernel-x86_64-fedora.config
[kernel-ark]: https://gitlab.com/cki-project/kernel-ark/-/raw/os-build/redhat/configs/common/generic/CONFIG_SECRETMEM
[fedora-zram]: https://fedoraproject.org/wiki/Changes/SwapOnZRAM
[debian-sb]: https://wiki.debian.org/SecureBoot
[sd-system-conf]: https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html
[sd-coredump]: https://www.freedesktop.org/software/systemd/man/latest/systemd-coredump.html
[sd-src-rlimit]: https://github.com/systemd/systemd/blob/v257/src/coredump/coredump.c#L472-L479
[sd-src-submit]: https://github.com/systemd/systemd/blob/v257/src/coredump/coredump.c#L913-L935
[sd-src-privs]: https://github.com/systemd/systemd/blob/v257/src/coredump/coredump.c#L887-L893
[sd-src-environ]: https://github.com/systemd/systemd/blob/v257/src/coredump/coredump.c#L1458-L1459
[apport-start]: https://github.com/canonical/apport/blob/81be06ba7e01ac616921789ea99392258a58b2dd/data/apport#L696-L705
[apport-unpackaged]: https://github.com/canonical/apport/blob/81be06ba7e01ac616921789ea99392258a58b2dd/data/apport#L1141-L1149
[apport-environ]: https://github.com/canonical/apport/blob/81be06ba7e01ac616921789ea99392258a58b2dd/apport/report.py#L883-L898
[moby-seccomp]: https://github.com/moby/profiles/blob/4b8214fc4971e06172938a1f1554ccff6647ee80/seccomp/default.json#L217-L354
[zeroize]: https://docs.rs/zeroize/1.9.1/zeroize/
[secrecy]: https://docs.rs/secrecy/0.10.3/secrecy/
[secrets]: https://docs.rs/secrets/1.3.0/secrets/
[secrets-src]: https://docs.rs/crate/secrets/1.3.0/source/src/ffi/sodium.rs
[memsec-mlock]: https://docs.rs/crate/memsec/0.7.0/source/src/mlock.rs
[memsec-alloc]: https://docs.rs/crate/memsec/0.7.0/source/src/alloc/mod.rs
[memsec-memfd]: https://docs.rs/crate/memsec/0.7.0/source/src/alloc/allocext/linux.rs
[memsec-readme]: https://docs.rs/crate/memsec/0.7.0/source/README.md
[region-lock]: https://docs.rs/region/4.0.1/region/fn.lock.html
[std-exec]: https://doc.rust-lang.org/std/os/unix/process/trait.CommandExt.html#tymethod.exec
[std-exit]: https://doc.rust-lang.org/std/process/fn.exit.html
[std-abort]: https://doc.rust-lang.org/std/process/fn.abort.html
[std-env-src]: https://github.com/rust-lang/rust/blob/1.90.0/library/std/src/sys/process/env.rs#L24-L54
[std-envp-src]: https://github.com/rust-lang/rust/blob/1.90.0/library/std/src/sys/process/unix/common.rs#L335-L393
[mac-mlock]: https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/mlock.2.html
[mac-ptrace]: https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/ptrace.2.html
[xnu-limits]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/bsd_init.c#L648-L658
[xnu-dflcsiz]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/i386/vmparam.h#L55-L60
[xnu-core]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_core.c#L109-L138
[xnu-core-limit]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_core.c#L457-L478
[xnu-denyattach]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/mach_process.c#L568-L571
[xnu-exec]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_exec.c#L5223-L5225
[xnu-procargs]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_sysctl.c#L1387-L1406
[xnu-procargs-uid]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_sysctl.c#L1447-L1451
[xnu-csrestricted]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_cs.c#L1738-L1748
[apple-swap]: https://support.apple.com/guide/security/role-of-apple-file-system-seca6147599e/web
[apple-dts-core]: https://developer.apple.com/forums/thread/694233
[apple-debugger]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger
[apple-hardened]: https://developer.apple.com/documentation/security/hardened-runtime
