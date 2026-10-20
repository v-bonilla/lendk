//! `lendk unlock [KEY|@GROUP...]`: decrypt the keys under run's rules, which unlocks GnuPG, and
//! discard the values.

use crate::cli::Env;
use crate::failure::Failure;
use crate::map::{self, Paths};
use crate::pass;
use crate::run::{self, Ending};
use crate::tables;

/// Runs `lendk unlock`; on success the caller prints `unlocked`.
pub fn unlock(
    env: &Env,
    paths: &Paths,
    interactive: bool,
    timeout: u64,
    words: &[&[u8]],
) -> Result<(), Ending> {
    for word in words {
        if let Some(problem) = map::bad_word(word, None) {
            return Err(Failure::new(&tables::USAGE, problem).into());
        }
    }
    map::check_paths(&paths.map)?;
    let keys = if words.is_empty() {
        if std::fs::metadata(map::path(&paths.map)).is_err() {
            return Err(Failure::new(
                &tables::MISSING_KEY_NOMAP,
                [&paths.map[..], b" does not exist"].concat(),
            )
            .into());
        }
        let Some(key) = map::first_key(&paths.map, |k| pass::has(paths, k))? else {
            return Err(Failure::new(
                &tables::MISSING_KEY_NONE,
                [b"no key mapped in ", &paths.map[..], b" is in the store"].concat(),
            )
            .into());
        };
        vec![key]
    } else {
        map::expand_keys(&paths.map, b"", words)?
    };
    let keys: Vec<&[u8]> = keys.iter().map(Vec::as_slice).collect();
    run::read_keys(env, paths, interactive, timeout, &keys)?;
    Ok(())
}
