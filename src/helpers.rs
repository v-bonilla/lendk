//! Helpers: the only module that starts processes or sets their environment. A helper gets an
//! environment built from scratch (ADR 0006): PATH without the shim directory and the
//! allowlisted caller variables, and stdin from /dev/null.
#![allow(clippy::disallowed_methods)]

use crate::cli::Env;
use crate::plaintext::Plaintext;
use crate::sys;
use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::process::{Child, Command, Stdio};

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

/// Starts `program` with `args` under `vars` alone, stdin /dev/null, stdout a pipe, stderr into
/// `stderr`, and `status` as descriptor 9.
pub fn spawn(
    program: &str,
    args: &[&[u8]],
    vars: &[(Vec<u8>, Vec<u8>)],
    stderr: File,
    status: &File,
) -> io::Result<Child> {
    let mut command = Command::new(program);
    command
        .args(args.iter().map(|a| OsStr::from_bytes(a)))
        .env_clear()
        .envs(
            vars.iter()
                .map(|(n, v)| (OsStr::from_bytes(n), OsStr::from_bytes(v))),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(stderr);
    sys::status_fd_9(&mut command, status.as_raw_fd());
    command.spawn()
}

/// Reads all of `fd` with read(2), keeping in `plaintext` only the first line, without its
/// newline. The rest is read into a scratch buffer that is zeroed.
pub fn read_first_line(fd: i32, plaintext: &mut Plaintext) -> io::Result<()> {
    loop {
        plaintext.reserve(64 * 1024)?;
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
    use std::time::Instant;

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
        read_first_line(out.as_raw_fd(), &mut plaintext).unwrap();
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
        read_first_line(out.as_raw_fd(), &mut plaintext).unwrap();
        child.wait().unwrap();
        assert_eq!(plaintext.as_bytes(), b"  a * b\\n  ");
    }
}
