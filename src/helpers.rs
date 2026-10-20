//! Helpers: the only module that starts processes or sets their environment. A helper gets an
//! environment built from scratch (ADR 0006): PATH without the shim directory and the
//! allowlisted caller variables, upgrade's download variables for its tools alone, and stdin
//! from /dev/null.
#![allow(clippy::disallowed_methods)]

use crate::cli::Env;
use crate::plaintext::Plaintext;
use crate::sys;
use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::process::{ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

/// The caller's PATH without the shim directory, whether named as is or reached another way.
pub fn path_without(env: &Env, shims: &[u8]) -> Vec<u8> {
    let path = env.get("PATH").unwrap_or_default();
    let dirs: Vec<&[u8]> = path
        .split(|&c| c == b':')
        .filter(|d| *d != shims && !(d.starts_with(b"/") && sys::same_file(d, shims)))
        .collect();
    dirs.join(&b':')
}

fn allowed(name: &[u8]) -> bool {
    const NAMES: &[&str] = &[
        "HOME",
        "USER",
        "LOGNAME",
        "LANG",
        "TERM",
        "TMPDIR",
        "DISPLAY",
        "WAYLAND_DISPLAY",
        "XAUTHORITY",
        "DBUS_SESSION_BUS_ADDRESS",
        "XDG_RUNTIME_DIR",
        "GNUPGHOME",
        "PINENTRY_USER_DATA",
    ];
    if name == b"PASSWORD_STORE_GPG_OPTS" || name == b"GPG_TTY" {
        return false;
    }
    NAMES.iter().any(|n| n.as_bytes() == name)
        || name.starts_with(b"LC_")
        || name.starts_with(b"PASSWORD_STORE_")
}

/// A helper's environment: PATH, the allowlisted caller variables, then `extra`.
pub fn helper_env(env: &Env, shims: &[u8], extra: &[(&[u8], Vec<u8>)]) -> Vec<(Vec<u8>, Vec<u8>)> {
    let mut out = vec![(b"PATH".to_vec(), path_without(env, shims))];
    for (name, value) in env.entries() {
        if allowed(name) && !out.iter().any(|(n, _)| n == name) {
            out.push((name.to_vec(), value.to_vec()));
        }
    }
    for (name, value) in extra {
        out.push((name.to_vec(), value.clone()));
    }
    out
}

/// The environment of `upgrade`'s download and unpack tools: a helper's, plus the caller's proxy
/// and certificate variables a download needs (ADR 0006).
pub fn download_env(env: &Env, shims: &[u8]) -> Vec<(Vec<u8>, Vec<u8>)> {
    const NET: [&str; 11] = [
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "NO_PROXY",
        "ALL_PROXY",
        "https_proxy",
        "http_proxy",
        "no_proxy",
        "all_proxy",
        "CURL_CA_BUNDLE",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
    ];
    let net: Vec<(&[u8], Vec<u8>)> = NET
        .iter()
        .filter_map(|n| Some((n.as_bytes(), env.get(n)?.to_vec())))
        .collect();
    helper_env(env, shims, &net)
}

/// The watchdog: a fork of lendk in a process group of its own, so a signal to lendk's group
/// misses it. Each helper writes its PID to the watchdog before it leaves lendk's group. When
/// lendk ends without saying it is done, a KILL included, the watchdog sees its pipe close, ends
/// the last helper's group and removes the call's temporary directory and `staged`, upgrade's
/// file beside lendk (ADR 0005).
pub struct Watchdog {
    pid: i32,
    ctl: Option<OwnedFd>,
}

impl Watchdog {
    pub fn start(tmp: &[u8], staged: Option<&[u8]>) -> io::Result<Self> {
        let (read, write) = sys::pipe()?;
        let pid = sys::fork()?;
        if pid == 0 {
            drop(write);
            sys::detach();
            watch(read.as_raw_fd(), tmp, staged);
        }
        drop(read);
        sys::setpgid(pid, pid);
        Ok(Watchdog {
            pid,
            ctl: Some(write),
        })
    }

    /// Starts `program` with `args` under `vars` alone, in a process group of its own known to
    /// the watchdog: stdin /dev/null, stdout into `stdout` or a pipe, stderr into `stderr` or
    /// /dev/null, and `status`, when given, as descriptor 9.
    pub fn spawn(
        &self,
        program: &[u8],
        args: &[&[u8]],
        vars: &[(Vec<u8>, Vec<u8>)],
        (stdout, stderr): (Option<File>, Option<File>),
        status: Option<&File>,
    ) -> io::Result<Job> {
        let mut command = Command::new(OsStr::from_bytes(program));
        command
            .args(args.iter().map(|a| OsStr::from_bytes(a)))
            .env_clear()
            .envs(
                vars.iter()
                    .map(|(n, v)| (OsStr::from_bytes(n), OsStr::from_bytes(v))),
            )
            .stdin(Stdio::null())
            .stdout(stdout.map_or_else(Stdio::piped, Stdio::from))
            .stderr(stderr.map_or_else(Stdio::null, Stdio::from));
        let report = self.ctl.as_ref().map_or(-1, AsRawFd::as_raw_fd);
        sys::helper_child(&mut command, report, status.map(AsRawFd::as_raw_fd));
        let mut child = command.spawn()?;
        let stdout = child.stdout.take();
        let pid = i32::try_from(child.id()).unwrap_or(-1);
        // The child is reaped through its PID from here on.
        std::mem::forget(child);
        Ok(Job {
            pid,
            stdout,
            reaped: None,
        })
    }
}

impl Drop for Watchdog {
    /// Tells the watchdog the call is done, and reaps it.
    fn drop(&mut self) {
        if let Some(ctl) = self.ctl.take() {
            sys::write(ctl.as_raw_fd(), &0i32.to_ne_bytes());
        }
        sys::wait(self.pid);
    }
}

/// The watchdog's loop, in the forked child.
fn watch(ctl: i32, tmp: &[u8], staged: Option<&[u8]>) -> ! {
    let mut pid = 0;
    let mut buf = [0u8; 4];
    while let Ok(4) = sys::read(ctl, &mut buf) {
        pid = i32::from_ne_bytes(buf);
        if pid == 0 {
            sys::exit_now(0);
        }
    }
    if pid > 0 {
        end_group(pid, || {});
    }
    let _ = std::fs::remove_dir_all(crate::map::path(tmp));
    if let Some(staged) = staged {
        let _ = std::fs::remove_file(crate::map::path(staged));
    }
    sys::exit_now(0)
}

/// Sends TERM and CONT to `pid` and its group, waits up to 0.3 s for both to go, calling `reap`
/// meanwhile, then sends KILL.
fn end_group(pid: i32, mut reap: impl FnMut()) {
    for sig in [libc::SIGTERM, libc::SIGCONT] {
        sys::kill(-pid, sig);
        sys::kill(pid, sig);
    }
    for _ in 0..30 {
        reap();
        if !sys::kill(-pid, 0) && !sys::kill(pid, 0) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    sys::kill(-pid, libc::SIGKILL);
    sys::kill(pid, libc::SIGKILL);
}

/// A running helper: its stdout and its process group, which ends with the call.
pub struct Job {
    pid: i32,
    stdout: Option<ChildStdout>,
    reaped: Option<i32>,
}

impl Job {
    pub fn stdout(&self) -> i32 {
        self.stdout.as_ref().map_or(-1, AsRawFd::as_raw_fd)
    }

    /// Waits until `deadline` for the helper to exit: whether it exited with status 0, or None
    /// when the deadline passed, which ends its group.
    pub fn wait(&mut self, deadline: Instant) -> Option<bool> {
        self.stdout = None;
        let mut pause = Duration::from_micros(50);
        loop {
            if let Some(status) = sys::try_wait(self.pid) {
                self.reaped = Some(status);
                return Some(libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 0);
            }
            if Instant::now() >= deadline {
                self.end();
                return None;
            }
            std::thread::sleep(pause);
            pause = (pause * 2).min(Duration::from_millis(10));
        }
    }

    /// Ends the helper's group and reaps the helper.
    pub fn end(&mut self) {
        self.stdout = None;
        if self.reaped.is_some() {
            return;
        }
        let pid = self.pid;
        let reaped = &mut self.reaped;
        end_group(pid, || {
            if reaped.is_none() {
                *reaped = sys::try_wait(pid);
            }
        });
        if self.reaped.is_none() {
            sys::wait(pid);
            self.reaped = Some(0);
        }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        self.end();
    }
}

/// Milliseconds left until `deadline`, at least 0.
fn left(deadline: Instant) -> i32 {
    let ms = deadline
        .saturating_duration_since(Instant::now())
        .as_millis();
    i32::try_from(ms).unwrap_or(i32::MAX)
}

fn timed_out() -> io::Error {
    io::Error::from(io::ErrorKind::TimedOut)
}

/// Reads all of `fd` with read(2) until `deadline`, keeping in `plaintext` only the first line,
/// without its newline. The rest is read into a scratch buffer that is zeroed. Past the deadline
/// it fails with `TimedOut`.
pub fn read_first_line(fd: i32, plaintext: &mut Plaintext, deadline: Instant) -> io::Result<()> {
    let ready = |fd| loop {
        if sys::readable_within(fd, left(deadline))? {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(timed_out());
        }
    };
    loop {
        if plaintext.spare().is_empty() {
            plaintext.reserve(1)?;
        }
        ready(fd)?;
        let before = plaintext.len();
        let n = sys::read(fd, plaintext.spare())?;
        if n == 0 {
            return Ok(());
        }
        plaintext.commit(n);
        if let Some(i) = plaintext.as_bytes()[before..]
            .iter()
            .position(|&c| c == b'\n')
        {
            plaintext.truncate(before + i);
            break;
        }
    }
    let mut scratch = [0u8; 4096];
    let drained = loop {
        if let Err(e) = ready(fd) {
            break Err(e);
        }
        match sys::read(fd, &mut scratch) {
            Ok(0) => break Ok(()),
            Ok(_) => {}
            Err(e) => break Err(e),
        }
    };
    zeroize::Zeroize::zeroize(&mut scratch);
    drained
}

#[cfg(test)]
mod tests {
    use super::*;

    fn far() -> Instant {
        Instant::now() + Duration::from_secs(60)
    }

    #[test]
    fn a_200_kb_first_line_reads_in_under_1_s() {
        let mut child = Command::new("sh")
            .args([
                "-c",
                "head -c 200000 /dev/zero | tr '\\000' x; printf '\\nsecond\\n'",
            ])
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let out = child.stdout.take().unwrap();
        let mut plaintext = Plaintext::with_capacity(16).unwrap();
        plaintext.push(b"K=").unwrap();
        let started = Instant::now();
        read_first_line(out.as_raw_fd(), &mut plaintext, far()).unwrap();
        assert!(started.elapsed().as_secs_f64() < 1.0);
        child.wait().unwrap();
        assert_eq!(plaintext.len(), 200_002);
        assert!(plaintext.as_bytes()[2..].iter().all(|&c| c == b'x'));
    }

    #[test]
    fn the_value_is_the_first_line_with_spaces_and_glob_characters_kept() {
        let mut child = Command::new("printf")
            .arg("  a * b\\\\n  \\nsecond\\n")
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let out = child.stdout.take().unwrap();
        let mut plaintext = Plaintext::with_capacity(16).unwrap();
        read_first_line(out.as_raw_fd(), &mut plaintext, far()).unwrap();
        child.wait().unwrap();
        assert_eq!(plaintext.as_bytes(), b"  a * b\\n  ");
    }
}
