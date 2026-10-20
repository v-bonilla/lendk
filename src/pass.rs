//! Pass reader: `pass show PREFIX/KEY` for each key, its first line into the Plaintext buffer,
//! and a failure through gpg's status code (ADR 0004).

use crate::cli::Env;
use crate::failure::Failure;
use crate::helpers;
use crate::map::{Paths, path};
use crate::plaintext::Plaintext;
use crate::sys;
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;

/// Whether the store holds an entry for `key`.
pub fn has(paths: &Paths, key: &[u8]) -> bool {
    let entry = [&paths.store[..], b"/", &paths.prefix, b"/", key, b".gpg"].concat();
    std::fs::metadata(path(&entry)).is_ok_and(|m| m.is_file())
}

/// A private temporary directory for the backend's stderr and status, removed on drop.
struct TempDir(Vec<u8>);

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(path(&self.0));
    }
}

/// The entry name `PREFIX/KEY`.
fn entry(paths: &Paths, key: &[u8]) -> Vec<u8> {
    [&paths.prefix[..], b"/", key].concat()
}

fn private_file(name: &[u8]) -> std::io::Result<File> {
    OpenOptions::new()
        .write(true)
        .read(true)
        .create_new(true)
        .mode(0o600)
        .open(path(name))
}

/// Reads each key's value as a `KEY=value` entry ended by NUL, and returns each entry's offset.
pub fn read(
    env: &Env,
    paths: &Paths,
    interactive: bool,
    keys: &[&[u8]],
    plaintext: &mut Plaintext,
) -> Result<Vec<usize>, Failure> {
    let tmp_base = env
        .get("TMPDIR")
        .filter(|t| !t.is_empty())
        .unwrap_or(b"/tmp");
    let tmp = sys::mkdtemp(&[tmp_base, b"/lendk.XXXXXX"].concat()).map_err(|_| {
        Failure::new(
            "write",
            [tmp_base, b": cannot create a temporary directory"].concat(),
        )
        .with("PATH", tmp_base)
    })?;
    let tmp = TempDir(tmp);
    let mut opts = env
        .get("PASSWORD_STORE_GPG_OPTS")
        .unwrap_or_default()
        .to_vec();
    if !opts.is_empty() {
        opts.push(b' ');
    }
    opts.extend_from_slice(b"--status-fd 9");
    if !interactive {
        opts.extend_from_slice(b" --pinentry-mode error");
    }
    let mut extra: Vec<(&[u8], Vec<u8>)> = vec![(b"PASSWORD_STORE_GPG_OPTS", opts)];
    if let Some(tty) = env.get("GPG_TTY") {
        extra.push((b"GPG_TTY", tty.to_vec()));
    }
    let vars = helpers::helper_env(env, &paths.shims, &extra);
    let mut offsets = Vec::new();
    for key in keys {
        let name = entry(paths, key);
        let err_path = [&tmp.0[..], b"/err.", *key].concat();
        let status_path = [&tmp.0[..], b"/status.", *key].concat();
        let io_fail = |_| {
            Failure::new(
                "write",
                [&tmp.0[..], b": cannot write the backend's files"].concat(),
            )
            .with("PATH", tmp.0.clone())
        };
        let stderr = private_file(&err_path).map_err(io_fail)?;
        let status = private_file(&status_path).map_err(io_fail)?;
        let offset = plaintext.len();
        let mut child = helpers::spawn("pass", &[b"show", &name], &vars, stderr, &status)
            .map_err(|e| decrypt(&name, key, e.to_string().as_bytes()))?;
        drop(status);
        let stdout = child.stdout.take().expect("stdout is a pipe");
        let pushed = plaintext
            .push(key)
            .and_then(|()| plaintext.push(b"="))
            .and_then(|()| helpers::read_first_line(stdout.as_raw_fd(), plaintext));
        drop(stdout);
        let exited = child.wait();
        let value_start = offset + key.len() + 1;
        if !exited.as_ref().is_ok_and(|s| s.success()) || pushed.is_err() {
            plaintext.truncate(offset);
            return Err(classify(&tmp.0, &name, key, interactive));
        }
        if plaintext.len() == value_start {
            plaintext.truncate(offset);
            return Err(Failure::new(
                "missing-key:empty",
                [&name[..], b" has an empty first line"].concat(),
            )
            .with("KEY", *key));
        }
        plaintext.push(b"\0").map_err(io_fail)?;
        offsets.push(offset);
    }
    Ok(offsets)
}

fn decrypt(name: &[u8], key: &[u8], said: &[u8]) -> Failure {
    Failure::new("decrypt", [name, b": gpg says: ", said].concat()).with("KEY", key)
}

/// The failure of a pass call: gpg's first ERROR status code, else gpg's last stderr line.
fn classify(tmp: &[u8], name: &[u8], key: &[u8], interactive: bool) -> Failure {
    let status = std::fs::read(path(&[tmp, b"/status.", key].concat())).unwrap_or_default();
    let code = status
        .split(|&c| c == b'\n')
        .find(|l| l.starts_with(b"[GNUPG:] ERROR "))
        .and_then(|l| {
            l.split(|c| c.is_ascii_whitespace())
                .filter(|f| !f.is_empty())
                .nth(3)
                .and_then(|f| std::str::from_utf8(f).ok()?.parse::<u64>().ok())
        })
        .map(|c| c & 65535);
    match code {
        Some(85 | 99) if !interactive => {
            return Failure::new(
                "locked",
                [
                    name,
                    b" needs the gpg passphrase and this call cannot prompt",
                ]
                .concat(),
            )
            .with("KEY", key);
        }
        Some(99) => {
            return Failure::new(
                "canceled",
                [b"passphrase entry for ", name, b" was canceled"].concat(),
            )
            .with("KEY", key);
        }
        _ => {}
    }
    let stderr = std::fs::read(path(&[tmp, b"/err.", key].concat())).unwrap_or_default();
    let last = stderr
        .split(|&c| c == b'\n')
        .rfind(|l| !l.is_empty())
        .unwrap_or(b"pass failed with no message");
    let last = last.strip_prefix(b"gpg: ").unwrap_or(last);
    decrypt(name, key, last.strip_suffix(b".").unwrap_or(last))
}
