//! Pass reader: `pass show PREFIX/KEY` for each key, its first line into the Plaintext buffer,
//! and a failure through gpg's status code (ADR 0004), all within LENDK_TIMEOUT.

use crate::cli::Env;
use crate::failure::Failure;
use crate::helpers;
use crate::map::{Paths, path};
use crate::plaintext::Plaintext;
use crate::sys;
use std::fs::{File, OpenOptions};
use std::os::unix::fs::OpenOptionsExt;
use std::time::{Duration, Instant};

/// Whether the store holds an entry for `key`.
pub fn has(paths: &Paths, key: &[u8]) -> bool {
    let entry = [&paths.store[..], b"/", &paths.prefix, b"/", key, b".gpg"].concat();
    std::fs::metadata(path(&entry)).is_ok_and(|m| m.is_file())
}

/// A private temporary directory for the backend's stderr and status, removed on drop.
pub struct TempDir(pub Vec<u8>);

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

fn words(text: &[u8]) -> impl Iterator<Item = &[u8]> {
    text.split(u8::is_ascii_whitespace)
        .filter(|w| !w.is_empty())
}

/// Whether gpg is set to prompt on the terminal itself: `pinentry-mode loopback`, the last
/// setting in gpg.conf or else in the caller's PASSWORD_STORE_GPG_OPTS.
fn loopback(conf: &[u8], opts: &[u8]) -> bool {
    let mut mode: &[u8] = b"";
    for line in conf.split(|&c| c == b'\n') {
        let mut line = words(line.split(|&c| c == b'#').next().unwrap_or_default());
        if line.next() == Some(b"pinentry-mode") {
            mode = line.next().unwrap_or_default();
        }
    }
    let mut prev: &[u8] = b"";
    for word in words(opts) {
        if prev == b"--pinentry-mode" {
            mode = word;
        }
        if let Some(m) = word.strip_prefix(b"--pinentry-mode=") {
            mode = m;
        }
        prev = word;
    }
    mode == b"loopback"
}

fn gpg_conf(env: &Env) -> Vec<u8> {
    let home = match env.get("GNUPGHOME").filter(|h| !h.is_empty()) {
        Some(h) => h.to_vec(),
        None => [env.get("HOME").unwrap_or_default(), b"/.gnupg"].concat(),
    };
    std::fs::read(path(&[&home[..], b"/gpg.conf"].concat())).unwrap_or_default()
}

/// The backend's GPG_TTY: in an interactive call whose GPG_TTY names no character device,
/// stdin's terminal, else stderr's; otherwise the caller's.
fn gpg_tty(env: &Env, interactive: bool) -> Option<Vec<u8>> {
    use std::os::unix::fs::FileTypeExt;
    let caller = env.get("GPG_TTY");
    let char_device = caller
        .is_some_and(|t| std::fs::metadata(path(t)).is_ok_and(|m| m.file_type().is_char_device()));
    if interactive && !char_device {
        for fd in [0, 2] {
            if sys::is_terminal(fd)
                && let Some(name) = sys::ttyname(fd)
            {
                return Some(name);
            }
        }
    }
    caller.map(<[u8]>::to_vec)
}

/// The first executable `name` on `path_var`.
pub fn find(path_var: &[u8], name: &[u8]) -> Option<Vec<u8>> {
    path_var.split(|&c| c == b':').find_map(|dir| {
        let dir = if dir.is_empty() { &b"."[..] } else { dir };
        let file = [dir, b"/", name].concat();
        (std::fs::metadata(path(&file)).is_ok_and(|m| m.is_file()) && sys::executable(&file))
            .then_some(file)
    })
}

/// The version in gpg's first `--version` line, after `gpg (GnuPG...) `.
fn gnupg_version(first: &[u8]) -> &[u8] {
    first
        .strip_prefix(b"gpg (GnuPG")
        .and_then(|rest| {
            let i = rest.windows(2).position(|w| w == b") ")?;
            Some(&rest[i + 2..])
        })
        .unwrap_or(first)
}

/// Whether `version` is GnuPG 2.4 or later: MAJOR.MINOR.PATCH with an optional -SUFFIX.
fn gnupg_ok(version: &[u8]) -> bool {
    let (numbers, suffix) = match version.iter().position(|&c| c == b'-') {
        Some(i) => (&version[..i], Some(&version[i + 1..])),
        None => (version, None),
    };
    if suffix
        .is_some_and(|s| s.is_empty() || !s.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'.'))
    {
        return false;
    }
    let parts: Vec<Option<u64>> = numbers
        .split(|&c| c == b'.')
        .map(|p| {
            if p.is_empty() || !p.iter().all(u8::is_ascii_digit) {
                return None;
            }
            std::str::from_utf8(p).ok()?.parse().ok()
        })
        .collect();
    match parts[..] {
        [Some(major), Some(minor), Some(_)] => major > 2 || (major == 2 && minor >= 4),
        _ => false,
    }
}

/// The GnuPG 2.4 floor, for the gpg pass uses: gpg2 when on PATH, else gpg. A missing gpg is
/// left to pass.
fn check_gnupg(
    watchdog: &helpers::Watchdog,
    vars: &[(Vec<u8>, Vec<u8>)],
    deadline: Instant,
) -> Result<(), Failure> {
    let path_var = vars
        .iter()
        .find(|(n, _)| n == b"PATH")
        .map(|(_, v)| v.as_slice())
        .unwrap_or_default();
    let Some(gpg) = find(path_var, b"gpg2").or_else(|| find(path_var, b"gpg")) else {
        return Ok(());
    };
    let mut out = Plaintext::with_capacity(256)
        .map_err(|_| Failure::new("write", "memory for gpg's version cannot be mapped"))?;
    if let Ok(mut job) = watchdog.spawn(&gpg, &[b"--version"], vars, (None, None), None) {
        let _ = helpers::read_first_line(job.stdout(), &mut out, deadline);
        job.wait(deadline);
    }
    let version = gnupg_version(out.as_bytes());
    if gnupg_ok(version) {
        return Ok(());
    }
    let shown: Vec<u8> = if version.is_empty() {
        b"no version".to_vec()
    } else {
        version
            .iter()
            .map(|&c| if (0x20..0x7f).contains(&c) { c } else { b'?' })
            .collect()
    };
    Err(Failure::new(
        "unsupported:gnupg",
        [
            b"GnuPG ",
            &shown[..],
            b" found; lendk needs GnuPG 2.4 or later",
        ]
        .concat(),
    ))
}

/// The GnuPG 2.4 floor as check sees it, within `timeout` seconds. The call has no temporary
/// directory for the watchdog to remove.
pub fn gnupg(env: &Env, paths: &Paths, timeout: u64) -> Result<(), Failure> {
    let deadline = Instant::now() + Duration::from_secs(timeout);
    let watchdog = helpers::Watchdog::start(b"", None).map_err(|e| {
        Failure::new(
            "write",
            [b"cannot start the watchdog: ", e.to_string().as_bytes()].concat(),
        )
    })?;
    check_gnupg(
        &watchdog,
        &helpers::helper_env(env, &paths.shims, &[]),
        deadline,
    )
}

/// A test hook: pauses for LENDK_TEST_PAUSE seconds when LENDK_TEST_AT, `exec` when unset,
/// names `point`.
pub fn test_pause(env: &Env, point: &[u8]) {
    if env.get("LENDK_TEST_AT").unwrap_or(b"exec") == point
        && let Some(&[n @ b'0'..=b'9']) = env.get("LENDK_TEST_PAUSE")
    {
        std::thread::sleep(Duration::from_secs(u64::from(n - b'0')));
    }
}

/// Reads each key's value as a `KEY=value` entry ended by NUL, and returns each entry's offset.
/// All of it, the GnuPG check included, ends within `timeout` seconds, and no helper outlives
/// the call.
pub fn read(
    env: &Env,
    paths: &Paths,
    interactive: bool,
    timeout: u64,
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
    let deadline = Instant::now() + Duration::from_secs(timeout);
    let watchdog = helpers::Watchdog::start(&tmp.0, None).map_err(|e| {
        Failure::new(
            "write",
            [b"cannot start the watchdog: ", e.to_string().as_bytes()].concat(),
        )
    })?;
    check_gnupg(
        &watchdog,
        &helpers::helper_env(env, &paths.shims, &[]),
        deadline,
    )?;
    let caller_opts = env.get("PASSWORD_STORE_GPG_OPTS").unwrap_or_default();
    let no_prompt = !interactive || loopback(&gpg_conf(env), caller_opts);
    let mut opts = caller_opts.to_vec();
    if !opts.is_empty() {
        opts.push(b' ');
    }
    opts.extend_from_slice(b"--status-fd 9");
    if no_prompt {
        opts.extend_from_slice(b" --pinentry-mode error");
    }
    let mut extra: Vec<(&[u8], Vec<u8>)> = vec![(b"PASSWORD_STORE_GPG_OPTS", opts)];
    if let Some(tty) = gpg_tty(env, interactive) {
        extra.push((b"GPG_TTY", tty));
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
        let mut job = watchdog
            .spawn(
                b"pass",
                &[b"show", &name],
                &vars,
                (None, Some(stderr)),
                Some(&status),
            )
            .map_err(|e| decrypt(&name, key, e.to_string().as_bytes()))?;
        drop(status);
        if offsets.is_empty() {
            test_pause(env, b"job");
        }
        let pushed = plaintext
            .push(key)
            .and_then(|()| plaintext.push(b"="))
            .and_then(|()| helpers::read_first_line(job.stdout(), plaintext, deadline));
        let exited = if pushed
            .as_ref()
            .is_err_and(|e| e.kind() == std::io::ErrorKind::TimedOut)
        {
            job.end();
            None
        } else {
            job.wait(deadline)
        };
        let value_start = offset + key.len() + 1;
        let Some(success) = exited else {
            plaintext.truncate(offset);
            let within = format!(": gpg did not finish within {timeout} s");
            return Err(
                Failure::new("timeout", [&name[..], within.as_bytes()].concat()).with("KEY", *key),
            );
        };
        if !success || pushed.is_err() {
            plaintext.truncate(offset);
            return Err(classify(&tmp.0, &name, key, no_prompt));
        }
        if plaintext.len() == value_start {
            plaintext.truncate(offset);
            return Err(Failure::new(
                "missing-key:empty",
                [&name[..], b" has an empty first line"].concat(),
            )
            .with("KEY", *key));
        }
        if plaintext.as_bytes()[value_start..].contains(&0) {
            plaintext.truncate(offset);
            return Err(Failure::new(
                "decrypt",
                [&name[..], b" has a NUL byte in its first line"].concat(),
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

/// The failure of a pass call: gpg's first ERROR status code, else gpg's last stderr line. A
/// call that cannot prompt reads codes 85 and 99 as `locked`.
fn classify(tmp: &[u8], name: &[u8], key: &[u8], no_prompt: bool) -> Failure {
    let status = std::fs::read(path(&[tmp, b"/status.", key].concat())).unwrap_or_default();
    let stderr = std::fs::read(path(&[tmp, b"/err.", key].concat())).unwrap_or_default();
    classify_output(&status, &stderr, name, key, no_prompt)
}

fn classify_output(
    status: &[u8],
    stderr: &[u8],
    name: &[u8],
    key: &[u8],
    no_prompt: bool,
) -> Failure {
    let code = status
        .split(|&c| c == b'\n')
        .find(|l| l.starts_with(b"[GNUPG:] ERROR "))
        .and_then(|l| {
            words(l)
                .nth(3)
                .and_then(|f| std::str::from_utf8(f).ok()?.parse::<u64>().ok())
        })
        .map(|c| c & 65535);
    match code {
        Some(85 | 99) if no_prompt => {
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
    let last = stderr
        .split(|&c| c == b'\n')
        .rfind(|l| !l.is_empty())
        .unwrap_or(b"pass failed with no message");
    let last = last.strip_prefix(b"gpg: ").unwrap_or(last);
    decrypt(name, key, last.strip_suffix(b".").unwrap_or(last))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_is_the_last_pinentry_mode_of_gpg_conf_then_the_options() {
        assert!(loopback(b"pinentry-mode loopback\n", b""));
        assert!(loopback(b"  pinentry-mode   loopback # typed\n", b""));
        assert!(!loopback(
            b"pinentry-mode loopback\npinentry-mode ask\n",
            b""
        ));
        assert!(!loopback(b"# pinentry-mode loopback\n", b""));
        assert!(loopback(b"", b"--x --pinentry-mode loopback"));
        assert!(loopback(b"", b"--pinentry-mode=loopback"));
        assert!(!loopback(
            b"pinentry-mode loopback\n",
            b"--pinentry-mode ask"
        ));
        assert!(!loopback(b"", b""));
    }

    #[test]
    fn the_gnupg_floor_is_2_4_with_a_strict_version() {
        for ok in ["2.4.0", "2.10.1", "2.4.0-beta", "2.5.12", "3.0.0"] {
            assert!(gnupg_ok(ok.as_bytes()), "{ok}");
        }
        for bad in [
            "2.2.27 ",
            "2.3.8",
            "1.4.23",
            "2.4",
            "x.y.z",
            "",
            "2.4.0-",
            "2.4.0-a b",
        ] {
            assert!(!gnupg_ok(bad.as_bytes()), "{bad}");
        }
        assert_eq!(gnupg_version(b"gpg (GnuPG) 2.4.4"), b"2.4.4");
        assert_eq!(gnupg_version(b"gpg (GnuPG/MacGPG2) 2.2.41"), b"2.2.41");
        assert_eq!(gnupg_version(b"something 1.0"), b"something 1.0");
    }

    #[test]
    fn the_status_code_not_the_text_classifies_per_mode() {
        let line = |code: &str| format!("[GNUPG:] ERROR pkdecrypt_failed {code}\n").into_bytes();
        let class = |code: &str, no_prompt| {
            classify_output(&line(code), b"gpg: x.\n", b"env/K", b"K", no_prompt).id
        };
        assert_eq!(class("67108949", true), "locked");
        assert_eq!(class("67108963", true), "locked");
        assert_eq!(class("67108963", false), "canceled");
        assert_eq!(class("67108949", false), "decrypt");
        assert_eq!(class("67108922", true), "decrypt");
        let failure = classify_output(
            b"",
            b"gpg: one\ngpg: decryption failed: x.\n\n",
            b"env/K",
            b"K",
            true,
        );
        assert_eq!(
            failure.text,
            b"env/K: gpg says: decryption failed: x".to_vec()
        );
    }
}
