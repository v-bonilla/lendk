//! `lendk run [KEY|@GROUP...] -- CMD [ARG...]`: read the map, resolve CMD, read the keys the
//! caller has not set, and exec CMD with them.

use crate::cli::Env;
use crate::exec;
use crate::failure::Failure;
use crate::map::{self, Paths};
use crate::pass;
use crate::plaintext::Plaintext;
use std::convert::Infallible;
use std::ffi::CStr;

/// What a failed run prints: every line but the last, which the caller reports and exits by.
pub struct Ending {
    pub before: Vec<Failure>,
    pub last: Failure,
}

impl From<Failure> for Ending {
    fn from(last: Failure) -> Self {
        Ending {
            before: Vec::new(),
            last,
        }
    }
}

fn usage(text: impl Into<Vec<u8>>) -> Ending {
    Failure::new("usage", text).into()
}

/// Whether `word` names an executable regular file, as bash's `type -P` finds it.
fn is_command(env: &Env, word: &[u8]) -> bool {
    let ok = |p: &[u8]| {
        std::fs::metadata(map::path(p)).is_ok_and(|m| m.is_file()) && crate::sys::executable(p)
    };
    if word.contains(&b'/') {
        return ok(word);
    }
    let path = env.get("PATH").unwrap_or_default();
    path.split(|&c| c == b':').any(|dir| {
        let dir = if dir.is_empty() { &b"."[..] } else { dir };
        ok(&[dir, b"/", word].concat())
    })
}

/// Runs `lendk run`; it returns only on failure.
pub fn run(
    env: &Env,
    paths: &Paths,
    interactive: bool,
    words: &[&'static CStr],
) -> Result<Infallible, Ending> {
    let Some(dash) = words.iter().position(|w| w.to_bytes() == b"--") else {
        for w in words.iter().map(|w| w.to_bytes()) {
            if !w.starts_with(b"@") && is_command(env, w) {
                return Err(usage(
                    [b"'", w, b"' is a command; put -- before it"].concat(),
                ));
            }
        }
        return Err(usage("run needs -- before the command"));
    };
    let named: Vec<&[u8]> = words[..dash].iter().map(|w| w.to_bytes()).collect();
    let Some((cmd, args)) = words[dash + 1..].split_first() else {
        return Err(usage("run needs a command after --"));
    };
    let cmd = cmd.to_bytes();
    for word in &named {
        if let Some(problem) = map::bad_word(word, None) {
            return Err(usage(problem));
        }
    }
    map::check_paths(&paths.map)?;
    let base = cmd.rsplit(|&c| c == b'/').next().unwrap_or(cmd);
    if named.is_empty() {
        let first_ok = base
            .first()
            .is_some_and(|c| c.is_ascii_alphanumeric() || *c == b'_' || *c == b'+');
        let rest_ok = base
            .iter()
            .all(|c| c.is_ascii_alphanumeric() || b"._+-".contains(c));
        if !first_ok || !rest_ok {
            return Err(usage([b"'", cmd, b"' names no valid command"].concat()));
        }
    }
    let keys = map::expand_keys(&paths.map, base, &named)?;
    let target = exec::resolve(env, &paths.shims, cmd)?;
    let to_read: Vec<&[u8]> = keys
        .iter()
        .map(Vec::as_slice)
        .filter(|k| env.get(k).is_none_or(<[u8]>::is_empty))
        .collect();
    let mut missing: Vec<Failure> = to_read
        .iter()
        .filter(|k| !pass::has(paths, k))
        .map(|k| {
            Failure::new(
                "missing-key",
                [&paths.prefix[..], b"/", k, b" is not in the store"].concat(),
            )
            .with("KEY", *k)
        })
        .collect();
    if let Some(last) = missing.pop() {
        return Err(Ending {
            before: missing,
            last,
        });
    }
    let capacity: usize = to_read.iter().map(|k| k.len() + 2 + 4096).sum();
    let mut plaintext = Plaintext::with_capacity(capacity)
        .map_err(|_| Failure::new("write", "memory for the values cannot be mapped"))?;
    let offsets = if to_read.is_empty() {
        Vec::new()
    } else {
        pass::read(env, paths, interactive, &to_read, &mut plaintext)?
    };
    if let Some(&[n @ b'0'..=b'9']) = env.get("LENDK_TEST_PAUSE") {
        std::thread::sleep(std::time::Duration::from_secs(u64::from(n - b'0')));
    }
    let injected: Vec<(&[u8], usize)> = to_read.iter().copied().zip(offsets).collect();
    let mut list: Vec<&[u8]> = Vec::new();
    let caller = env.get("LENDK_INJECTED").unwrap_or_default();
    let names = caller
        .split(|c| b" \t\n".contains(c))
        .filter(|n| !n.is_empty())
        .chain(injected.iter().map(|(k, _)| *k));
    for name in names {
        if !list.contains(&name) {
            list.push(name);
        }
    }
    let list = list.join(&b' ');
    Err(exec::exec(env, &target, cmd, args, plaintext, &injected, &list).into())
}
