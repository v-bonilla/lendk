//! Exec: the real command past the shim directory, the target's environment, and execve.

use crate::cli::Env;
use crate::failure::Failure;
use crate::map::{path, resolve_links};
use crate::plaintext::Plaintext;
use crate::sys;
use std::ffi::{CStr, CString, c_char};
use std::io::Read;

fn basename(cmd: &[u8]) -> &[u8] {
    cmd.rsplit(|&c| c == b'/').next().unwrap_or(cmd)
}

fn is_file(p: &[u8]) -> bool {
    std::fs::metadata(path(p)).is_ok_and(|m| m.is_file())
}

/// The first `n` bytes of a file, empty when it cannot be read.
fn head(p: &[u8], n: u64) -> Vec<u8> {
    let mut out = Vec::new();
    if let Ok(file) = std::fs::File::open(path(p)) {
        let _ = file.take(n).read_to_end(&mut out);
    }
    out
}

/// The file that `cmd` names: as given when it holds `/`, else the first executable regular
/// file on PATH outside the shim directory and any other lendk shim directory.
pub fn resolve(env: &Env, shims: &[u8], cmd: &[u8]) -> Result<Vec<u8>, Failure> {
    let target = if cmd.contains(&b'/') {
        cmd.to_vec()
    } else {
        let path_var = env.get("PATH").unwrap_or_default();
        let found = path_var.split(|&c| c == b':').find_map(|dir| {
            let dir = if dir.is_empty() { &b"."[..] } else { dir };
            let file = [dir, b"/", cmd].concat();
            if !is_file(&file) || !sys::executable(&file) || dir == shims {
                return None;
            }
            if sys::same_file(dir, shims) {
                return None;
            }
            if std::fs::symlink_metadata(path(&file)).is_ok_and(|m| m.is_symlink()) {
                let resolved = resolve_links(&file);
                let rdir = match resolved.iter().rposition(|&c| c == b'/') {
                    Some(0) => &b"/"[..],
                    Some(i) => &resolved[..i],
                    None => &b"."[..],
                };
                if sys::same_file(rdir, shims) {
                    return None;
                }
            }
            let text = head(&file, 513);
            let mut lines = text.split(|&c| c == b'\n');
            let second = lines.nth(1).unwrap_or_default();
            if second.starts_with(b"# lendk shim ") {
                return None;
            }
            Some(file)
        });
        found.ok_or_else(|| {
            Failure::new(
                "not-found",
                [cmd, b" is not on PATH outside ", shims].concat(),
            )
            .with("CMD", cmd)
        })?
    };
    let not_executable = |p: &[u8]| {
        Failure::new("exec", [p, b" is not executable"].concat())
            .with("PATH", p)
            .with("CMD", basename(cmd))
    };
    if !is_file(&target) || !sys::executable(&target) {
        return Err(not_executable(&target));
    }
    let first = head(&target, 256);
    let first = first.split(|&c| c == b'\n').next().unwrap_or_default();
    if let Some(rest) = first.strip_prefix(b"#!") {
        let interp = rest
            .split(|c| c.is_ascii_whitespace())
            .find(|f| !f.is_empty())
            .unwrap_or_default();
        if interp.starts_with(b"/") && !(is_file(interp) && sys::executable(interp)) {
            return Err(not_executable(interp));
        }
    }
    Ok(target)
}

/// Replaces lendk with `target`: argv is `cmd` as given and `args`, and the environment is the
/// caller's own entries in order, less those named like an injected key and LENDK_INJECTED,
/// then the injected entries and the new LENDK_INJECTED. On failure it zeroes the buffer and
/// returns the `exec` failure.
pub fn exec(
    env: &Env,
    target: &[u8],
    cmd: &[u8],
    args: &[&'static CStr],
    plaintext: Plaintext,
    injected: &[(&[u8], usize)],
    list: &[u8],
) -> Failure {
    let failure = Failure::new("exec", [target, b" is not executable"].concat())
        .with("PATH", target)
        .with("CMD", basename(cmd));
    let Ok(cmd0) = CString::new(cmd) else {
        return failure;
    };
    let Ok(list) = CString::new([&b"LENDK_INJECTED="[..], list].concat()) else {
        return failure;
    };
    let dropped =
        |name: &[u8]| name == b"LENDK_INJECTED" || injected.iter().any(|(k, _)| *k == name);
    let mut envp: Vec<*const c_char> = env
        .raw()
        .iter()
        .filter(|e| !dropped(Env::name(e.to_bytes())))
        .map(|e| e.as_ptr())
        .collect();
    envp.extend(injected.iter().map(|&(_, at)| plaintext.entry_ptr(at)));
    envp.push(list.as_ptr());
    let mut argv: Vec<&CStr> = vec![&cmd0];
    argv.extend_from_slice(args);
    let _error = sys::execve(target, &argv, &envp);
    drop(plaintext);
    failure
}
