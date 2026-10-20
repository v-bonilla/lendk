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
    if word.contains(&b'/') {
        return exec::is_executable(word);
    }
    exec::find(env.get("PATH").unwrap_or_default(), word).is_some()
}

/// Checks that every key is in the store, listing each missing one, then reads them all
/// within `timeout` seconds.
pub fn read_keys(
    env: &Env,
    paths: &Paths,
    interactive: bool,
    timeout: u64,
    keys: &[&[u8]],
) -> Result<(Plaintext, Vec<usize>), Ending> {
    let mut missing: Vec<Failure> = keys
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
    // 4 KiB per value keeps a typical call in one mapping small enough to mlock under a 64 KiB
    // RLIMIT_MEMLOCK; pass gives no length in advance, so a longer value grows it by copy.
    let capacity: usize = keys.iter().map(|k| k.len() + 2 + 4096).sum();
    let mut plaintext = Plaintext::with_capacity(capacity)
        .map_err(|_| Failure::new("write", "memory for the values cannot be mapped"))?;
    let offsets = if keys.is_empty() {
        Vec::new()
    } else {
        pass::read(env, paths, interactive, timeout, keys, &mut plaintext)?
    };
    Ok((plaintext, offsets))
}

/// Runs `lendk run`; it returns only on failure.
pub fn run(
    env: &Env,
    paths: &Paths,
    interactive: bool,
    timeout: u64,
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
    if named.is_empty() && !map::valid_cmd(base) {
        return Err(usage([b"'", cmd, b"' names no valid command"].concat()));
    }
    let keys = map::expand_keys(&paths.map, base, &named)?;
    let target = exec::resolve(env, &paths.shims, cmd)?;
    let to_read: Vec<&[u8]> = keys
        .iter()
        .map(Vec::as_slice)
        .filter(|k| env.get(k).is_none_or(<[u8]>::is_empty))
        .collect();
    let (plaintext, offsets) = read_keys(env, paths, interactive, timeout, &to_read)?;
    env.test_pause(b"exec", b"exec");
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
