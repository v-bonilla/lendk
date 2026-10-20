//! PROTOTYPE for #33, throwaway. Probes the kernel keyring the way lendk 2.0's identity
//! cache (#23) would use it, through raw system calls and the `libc` crate only (#27).
//! Every command prints `key=value` lines and never prints a payload: the payload is a
//! stand-in marker, compared in place.
//!
//! The cache keyring is `@u`, or `@s` when `LENDK_TEST_CACHE=session` (#23's test hook).
//!
//!   keyprobe ctx                       where this process stands: uid, user namespace, seccomp, keyrings
//!   keyprobe put DESC TTL [direct|staged] [TAG]
//!                                      cache the marker as a `user` key, possessor-only, expiring in TTL s
//!   keyprobe get DESC [plain|possess]  search the cache keyring, then read into a buffer this process owns
//!   keyprobe lock PREFIX [plain|possess]
//!                                      unlink every `user` key whose description starts with PREFIX
//!   keyprobe syscalls                  which keyring calls the environment allows, touching no `@u`
//!   keyprobe guard                     whether the session keyring is a fresh one a test may use
//!   keyprobe join-session [NAME] [share] -- CMD...
//!                                      join a fresh (or the named) session keyring, then exec CMD

use std::ffi::{CStr, CString};
use std::io::Write;

const KEY_SPEC_THREAD_KEYRING: i32 = -1;
const KEY_SPEC_SESSION_KEYRING: i32 = -3;
const KEY_SPEC_USER_KEYRING: i32 = -4;
const KEY_SPEC_USER_SESSION_KEYRING: i32 = -5;

const KEYCTL_GET_KEYRING_ID: i64 = 0;
const KEYCTL_JOIN_SESSION_KEYRING: i64 = 1;
const KEYCTL_SETPERM: i64 = 5;
const KEYCTL_DESCRIBE: i64 = 6;
const KEYCTL_LINK: i64 = 8;
const KEYCTL_UNLINK: i64 = 9;
const KEYCTL_SEARCH: i64 = 10;
const KEYCTL_READ: i64 = 11;
const KEYCTL_SET_TIMEOUT: i64 = 15;
const KEYCTL_MOVE: i64 = 30;

const KEY_POS_ALL: u32 = 0x3f00_0000;
const KEY_USR_VIEW: u32 = 0x0001_0000;
const KEY_USR_READ: u32 = 0x0002_0000;
const KEY_USR_WRITE: u32 = 0x0004_0000;
const KEY_USR_SEARCH: u32 = 0x0008_0000;
const KEY_USR_LINK: u32 = 0x0010_0000;

const MARKER: &[u8] = b"proto33-stand-in-for-an-age-identity-";

type Res = Result<i64, i32>;

fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

fn ename(e: i32) -> String {
    let n = match e {
        libc::EPERM => "EPERM",
        libc::ENOENT => "ENOENT",
        libc::EACCES => "EACCES",
        libc::EEXIST => "EEXIST",
        libc::EINVAL => "EINVAL",
        libc::ENOSYS => "ENOSYS",
        libc::EOPNOTSUPP => "EOPNOTSUPP",
        libc::EDQUOT => "EDQUOT",
        libc::ENOKEY => "ENOKEY",
        libc::EKEYEXPIRED => "EKEYEXPIRED",
        libc::EKEYREVOKED => "EKEYREVOKED",
        libc::EKEYREJECTED => "EKEYREJECTED",
        _ => return format!("errno{e}"),
    };
    n.to_string()
}

fn show(r: Res) -> String {
    match r {
        Ok(v) => format!("ok:{v}"),
        Err(e) => ename(e),
    }
}

fn keyctl(op: i64, a2: i64, a3: i64, a4: i64, a5: i64) -> Res {
    let r = unsafe { libc::syscall(libc::SYS_keyctl, op, a2, a3, a4, a5) };
    if r < 0 { Err(errno()) } else { Ok(r) }
}

fn add_key(ty: &str, desc: &str, payload: &[u8], ring: i32) -> Res {
    let ty = CString::new(ty).unwrap();
    let desc = CString::new(desc).unwrap();
    let r = unsafe {
        libc::syscall(libc::SYS_add_key, ty.as_ptr(), desc.as_ptr(), payload.as_ptr(), payload.len(), ring as i64)
    };
    if r < 0 { Err(errno()) } else { Ok(r) }
}

fn ring_id(spec: i32, create: bool) -> Res {
    keyctl(KEYCTL_GET_KEYRING_ID, spec as i64, create as i64, 0, 0)
}

fn describe(id: i64) -> Result<String, i32> {
    let mut buf = vec![0u8; 512];
    let n = keyctl(KEYCTL_DESCRIBE, id, buf.as_mut_ptr() as i64, buf.len() as i64, 0)? as usize;
    buf.truncate(n.saturating_sub(1).min(buf.len()));
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

fn ring_members(ring: i64) -> Result<Vec<i32>, i32> {
    let mut buf = vec![0i32; 1024];
    let n = keyctl(KEYCTL_READ, ring, buf.as_mut_ptr() as i64, (buf.len() * 4) as i64, 0)? as usize;
    buf.truncate((n / 4).min(1024));
    Ok(buf)
}

fn search(ring: i32, desc: &str) -> Res {
    let ty = CString::new("user").unwrap();
    let d = CString::new(desc).unwrap();
    keyctl(KEYCTL_SEARCH, ring as i64, ty.as_ptr() as i64, d.as_ptr() as i64, 0)
}

fn cache_ring() -> i32 {
    match std::env::var("LENDK_TEST_CACHE").as_deref() {
        Ok("session") => KEY_SPEC_SESSION_KEYRING,
        // A keyring named NAME inside the session keyring, made on first use: one per test,
        // under one fresh session keyring per suite run.
        Ok(v) if v.starts_with("name:") => {
            let name = CString::new(&v[5..]).unwrap();
            let ty = CString::new("keyring").unwrap();
            let found = keyctl(KEYCTL_SEARCH, KEY_SPEC_SESSION_KEYRING as i64, ty.as_ptr() as i64, name.as_ptr() as i64, 0);
            let r = found.or_else(|_| {
                let r = unsafe {
                    libc::syscall(libc::SYS_add_key, ty.as_ptr(), name.as_ptr(), std::ptr::null::<u8>(), 0usize, KEY_SPEC_SESSION_KEYRING as i64)
                };
                if r < 0 { Err(errno()) } else { Ok(r) }
            });
            match r {
                Ok(id) => id as i32,
                Err(e) => {
                    eprintln!("keyprobe: test keyring {}", ename(e));
                    std::process::exit(1)
                }
            }
        }
        Ok(other) => {
            eprintln!("keyprobe: LENDK_TEST_CACHE={other} is not understood");
            std::process::exit(2)
        }
        Err(_) => KEY_SPEC_USER_KEYRING,
    }
}

/// Possess the cache keyring's keys through this thread's own keyring. The thread keyring
/// dies with the thread and execve drops it, so nothing outside this process changes.
fn possess(cache: i32) -> Res {
    let t = ring_id(KEY_SPEC_THREAD_KEYRING, true)?;
    keyctl(KEYCTL_LINK, cache as i64, t, 0, 0)
}

fn proc_keys_line(serial: i64) -> String {
    let want = format!("{serial:08x} ");
    std::fs::read_to_string("/proc/keys")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with(&want)).map(|l| l.split_whitespace().collect::<Vec<_>>().join(" ")))
        .unwrap_or_else(|| "-".into())
}

fn status_field(name: &str) -> String {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with(name)).map(|l| l[name.len()..].trim().to_string()))
        .unwrap_or_else(|| "-".into())
}

fn cmd_ctx() {
    let userns = std::fs::read_link("/proc/self/ns/user").map(|p| p.display().to_string()).unwrap_or("-".into());
    println!("uid={} userns={} seccomp={}", unsafe { libc::getuid() }, userns, status_field("Seccomp:"));
    // Look the session keyring up before anything installs one, without creating it.
    let us = ring_id(KEY_SPEC_USER_SESSION_KEYRING, false);
    let s = ring_id(KEY_SPEC_SESSION_KEYRING, false);
    let u = ring_id(KEY_SPEC_USER_KEYRING, false);
    let sdesc = s.map_err(|e| e).and_then(|id| describe(id)).unwrap_or_else(|e| ename(e));
    println!("session={} session_desc={sdesc}", show(s));
    println!("user_session={} user={}", show(us), show(u));
    if let (Ok(s), Ok(u)) = (s, u) {
        let linked = match ring_members(s) {
            Ok(m) => (if m.contains(&(u as i32)) { "yes" } else { "no" }).to_string(),
            Err(e) => ename(e),
        };
        println!("session_links_user={linked} session_is_user_session={}", us.map(|us| us == s).unwrap_or(false));
    }
    match ring_members(KEY_SPEC_USER_KEYRING as i64) {
        Ok(m) => println!("user_keyring_members={}", m.len()),
        Err(e) => println!("user_keyring_members={}", ename(e)),
    }
}

fn cmd_put(desc: &str, ttl: i64, mode: &str, tag: &str) {
    let cache = cache_ring();
    let mut payload = MARKER.to_vec();
    payload.extend_from_slice(tag.as_bytes());
    let perm = KEY_POS_ALL as i64;
    let r = match mode {
        // add_key into the cache, then perms and expiry: the key sits with default perms and no
        // expiry between the calls, and a crash there leaves it until reboot.
        "direct" => add_key("user", desc, &payload, cache).and_then(|k| {
            keyctl(KEYCTL_SETPERM, k, perm, 0, 0)?;
            keyctl(KEYCTL_SET_TIMEOUT, k, ttl, 0, 0)?;
            Ok(k)
        }),
        // Build the key in this thread's keyring, then move it into the cache whole. A key with
        // the same type and description in the cache is displaced in the same step.
        "staged" => ring_id(KEY_SPEC_THREAD_KEYRING, true).and_then(|t| {
            let k = add_key("user", desc, &payload, t as i32)?;
            keyctl(KEYCTL_SETPERM, k, perm, 0, 0)?;
            keyctl(KEYCTL_SET_TIMEOUT, k, ttl, 0, 0)?;
            keyctl(KEYCTL_MOVE, k, t, cache as i64, 0)?;
            Ok(k)
        }),
        _ => {
            eprintln!("keyprobe: put mode is direct or staged");
            std::process::exit(2)
        }
    };
    match r {
        Ok(k) => println!("put=ok serial={k} mode={mode} tag={tag} proc_keys=\"{}\"", proc_keys_line(k)),
        Err(e) => println!("put={} mode={mode}", ename(e)),
    }
}

fn cmd_get(desc: &str, how: &str) {
    let cache = cache_ring();
    if how == "possess" {
        if let Err(e) = possess(cache) {
            println!("get={} step=possess", ename(e));
            return;
        }
    }
    let k = match search(cache, desc) {
        Ok(k) => k,
        Err(e) => {
            println!("get={} step=search how={how}", ename(e));
            return;
        }
    };
    // The caller's buffer, locked in memory, as #26's Plaintext would be.
    let mut buf = vec![0u8; 4096];
    unsafe { libc::mlock(buf.as_ptr() as *const libc::c_void, buf.len()) };
    let r = keyctl(KEYCTL_READ, k, buf.as_mut_ptr() as i64, buf.len() as i64, 0);
    match r {
        Ok(n) => {
            let n = n as usize;
            let tag = if n <= buf.len() && buf[..n].starts_with(MARKER) {
                String::from_utf8_lossy(&buf[MARKER.len()..n]).into_owned()
            } else {
                "?".into()
            };
            println!("get=hit serial={k} len={n} tag={tag} how={how} proc_keys=\"{}\"", proc_keys_line(k));
        }
        Err(e) => println!("get={} step=read serial={k} how={how}", ename(e)),
    }
    buf.iter_mut().for_each(|b| unsafe { std::ptr::write_volatile(b, 0) });
}

fn cmd_lock(prefix: &str, how: &str) {
    let cache = cache_ring();
    if how == "possess" {
        if let Err(e) = possess(cache) {
            println!("lock={} step=possess", ename(e));
            return;
        }
    }
    let members = match ring_members(cache as i64) {
        Ok(m) => m,
        Err(e) => {
            println!("lock={} step=list", ename(e));
            return;
        }
    };
    let (mut removed, mut unseen) = (0, 0);
    for k in members {
        match describe(k as i64) {
            Ok(d) => {
                let f: Vec<&str> = d.splitn(5, ';').collect();
                if f.len() == 5 && f[0] == "user" && f[4].starts_with(prefix) {
                    match keyctl(KEYCTL_UNLINK, k as i64, cache as i64, 0, 0) {
                        Ok(_) => removed += 1,
                        Err(e) => println!("unlink={} serial={k}", ename(e)),
                    }
                }
            }
            Err(_) => unseen += 1,
        }
    }
    println!("lock=ok removed={removed} undescribable={unseen} how={how}");
}

/// The guard a test call would pass before the hook touches anything: the session keyring
/// must be a fresh one, not a login's, which pam_keyinit links to `@u`, and not `@us`.
fn cmd_guard() {
    let s = ring_id(KEY_SPEC_SESSION_KEYRING, false);
    let us = ring_id(KEY_SPEC_USER_SESSION_KEYRING, false);
    let u = ring_id(KEY_SPEC_USER_KEYRING, false);
    let verdict = match (s, us, u) {
        (Ok(s), Ok(us), _) if s == us => "refuse: the session keyring is the user-session keyring".to_string(),
        (Ok(s), _, Ok(u)) => match ring_members(s) {
            Ok(m) if m.contains(&(u as i32)) => "refuse: the session keyring links @u, as a login's does".to_string(),
            Ok(_) => "ok".to_string(),
            Err(e) => format!("refuse: {}", ename(e)),
        },
        (s, _, u) => format!("refuse: session={} user={}", show(s), show(u)),
    };
    println!("guard={verdict}");
}

fn cmd_syscalls() {
    // Every call stays inside this process: the thread keyring and a fresh session keyring.
    let t = ring_id(KEY_SPEC_THREAD_KEYRING, true);
    println!("keyctl_get_thread_keyring={}", show(t));
    let ring = t.map(|t| t as i32).unwrap_or(KEY_SPEC_THREAD_KEYRING);
    println!("add_key={}", show(add_key("user", "proto33:syscalls", b"x", ring)));
    println!("keyctl_join_session={}", show(keyctl(KEYCTL_JOIN_SESSION_KEYRING, 0, 0, 0, 0)));
    println!("seccomp={}", status_field("Seccomp:"));
}

fn cmd_join_session(name: Option<&str>, share: bool, argv: &[String]) -> ! {
    let cname = name.map(|n| CString::new(n).unwrap());
    let p = cname.as_ref().map(|c| c.as_ptr() as i64).unwrap_or(0);
    match keyctl(KEYCTL_JOIN_SESSION_KEYRING, p, 0, 0, 0) {
        Ok(id) => {
            eprintln!("join-session=ok serial={id} desc={}", describe(id).unwrap_or_default());
            if share {
                let perm = KEY_POS_ALL | KEY_USR_VIEW | KEY_USR_READ | KEY_USR_WRITE | KEY_USR_SEARCH | KEY_USR_LINK;
                eprintln!("setperm={}", show(keyctl(KEYCTL_SETPERM, id, perm as i64, 0, 0)));
            }
        }
        Err(e) => {
            eprintln!("join-session={}", ename(e));
            std::process::exit(1)
        }
    }
    let _ = std::io::stderr().flush();
    let c: Vec<CString> = argv.iter().map(|a| CString::new(a.as_str()).unwrap()).collect();
    let mut ptrs: Vec<*const libc::c_char> = c.iter().map(|a| a.as_ptr()).collect();
    ptrs.push(std::ptr::null());
    unsafe { libc::execvp(ptrs[0], ptrs.as_ptr()) };
    eprintln!("exec={}", unsafe { CStr::from_ptr(libc::strerror(errno())) }.to_string_lossy());
    std::process::exit(127)
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let arg = |i: usize| a.get(i).map(String::as_str);
    match arg(1) {
        Some("ctx") => cmd_ctx(),
        Some("put") => cmd_put(
            arg(2).expect("DESC"),
            arg(3).expect("TTL").parse().expect("TTL is seconds"),
            arg(4).unwrap_or("staged"),
            arg(5).unwrap_or("a"),
        ),
        Some("get") => cmd_get(arg(2).expect("DESC"), arg(3).unwrap_or("plain")),
        Some("lock") => cmd_lock(arg(2).unwrap_or("lendk:"), arg(3).unwrap_or("plain")),
        Some("syscalls") => cmd_syscalls(),
        Some("guard") => cmd_guard(),
        Some("join-session") => {
            let dash = a.iter().position(|x| x == "--").expect("-- CMD");
            let opts = &a[2..dash];
            let name = opts.iter().find(|o| *o != "share").map(String::as_str);
            cmd_join_session(name, opts.iter().any(|o| o == "share"), &a[dash + 1..])
        }
        _ => {
            eprintln!("usage: keyprobe ctx|put|get|lock|syscalls|join-session (see the source)");
            std::process::exit(2)
        }
    }
}
