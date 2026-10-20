//! `lendk sync`, `lendk add [--force] CMD|@GROUP KEY|@GROUP...` and `lendk rm CMD|@GROUP
//! [KEY|@GROUP...]`: the map edits and the shim writes, under the write lock.

use crate::check;
use crate::cli::Env;
use crate::failure::{Failure, notice};
use crate::map::{self, Paths, Scan};
use crate::run::Ending;
use crate::shims::{self, Lock};
use crate::tables;
use crate::tables::{
    GUARDED_AGENT_CLIS, GUARDED_INTERPRETERS, GUARDED_LAUNCHERS, GUARDED_PACKAGE_TOOLS,
    GUARDED_SHELLS, RESERVED_CMDS,
};

/// What a verb hands back: its stdout and exit status, or the lines to report.
pub type Outcome = Result<(Vec<u8>, i32), Ending>;
pub type Verb = fn(&Call, &[&[u8]]) -> Outcome;

pub struct Call<'a> {
    pub env: &'a Env<'a>,
    pub paths: &'a Paths,
    pub interactive: bool,
    pub argv0: &'a [u8],
}

fn usage(text: impl Into<Vec<u8>>) -> Ending {
    Failure::new(&tables::USAGE, text).into()
}

/// The given failures as one ending: every one but the last is printed before it.
fn ending(mut failures: Vec<Failure>) -> Option<Ending> {
    let last = failures.pop()?;
    Some(Ending {
        before: failures,
        last,
    })
}

/// Writes the shims for the map under `lock`, then releases it; the map's violations, then
/// the write failures.
fn write_shims(call: &Call, mut lock: Lock) -> (Scan, Vec<Failure>) {
    let scan = map::scan(&call.paths.map);
    let lendk = shims::self_path(call.env, call.argv0);
    let report = shims::write(&call.paths.shims, &lendk, &scan, &mut lock);
    drop(lock);
    for n in &report.notices {
        notice(n);
    }
    let mut lines = scan.failures(&call.paths.map);
    lines.extend(report.failures);
    (scan, lines)
}

/// `lendk sync`: write shims to match the map, then report map violations and foreign files.
pub fn sync(call: &Call, words: &[&[u8]]) -> Outcome {
    if !words.is_empty() {
        return Err(usage("sync takes no arguments"));
    }
    map::check_paths(&call.paths.map)?;
    shims::check_dir(&call.paths.shims)?;
    let lock = Lock::take(&call.paths.shims, call.env.test_pause_secs())?;
    let (_, lines) = write_shims(call, lock);
    ending(lines).map_or(Ok((Vec::new(), 0)), Err)
}

fn check_name(name: &[u8]) -> Result<(), Ending> {
    if name.starts_with(b"@") {
        if let Some(problem) = map::bad_word(name, None) {
            return Err(usage(problem));
        }
    } else if !map::valid_cmd(name) {
        return Err(usage(map::invalid_cmd(name)));
    } else if RESERVED_CMDS.iter().any(|r| r.as_bytes() == name) {
        return Err(usage(map::runtime(name)));
    }
    Ok(())
}

fn is_guarded(name: &[u8]) -> bool {
    [
        GUARDED_SHELLS,
        GUARDED_INTERPRETERS,
        GUARDED_LAUNCHERS,
        GUARDED_PACKAGE_TOOLS,
        GUARDED_AGENT_CLIS,
    ]
    .concat()
    .iter()
    .any(|p| match p.strip_suffix('*') {
        Some(prefix) => name.starts_with(prefix.as_bytes()),
        None => p.as_bytes() == name,
    })
}

/// The whole map, which must be valid, then the verb's own check.
fn scan_valid(
    call: &Call,
    verb_check: &dyn Fn(&Scan) -> Result<(), Failure>,
) -> Result<Scan, Ending> {
    let scan = map::scan(&call.paths.map);
    if let Some(e) = ending(scan.failures(&call.paths.map)) {
        return Err(e);
    }
    verb_check(&scan)?;
    Ok(scan)
}

/// For add and rm: the owner and mode checks, the map read and the verb's check, all before
/// anything is created; then again under the lock.
fn edit_begin(
    call: &Call,
    verb_check: &dyn Fn(&Scan) -> Result<(), Failure>,
) -> Result<(Scan, Lock), Ending> {
    map::check_paths(&call.paths.map)?;
    let resolved = map::resolve_links(&call.paths.map);
    if std::fs::symlink_metadata(map::path(&resolved)).is_err() {
        shims::check_dir(map::dirname(&resolved))?;
    }
    shims::check_dir(&call.paths.shims)?;
    scan_valid(call, verb_check)?;
    let lock = Lock::take(&call.paths.shims, call.env.test_pause_secs())?;
    let scan = scan_valid(call, verb_check)?;
    Ok((scan, lock))
}

/// Writes the map under the lock; on failure the lock goes with the error.
fn edit_map(
    call: &Call,
    scan: &Scan,
    lock: &mut Lock,
    n: usize,
    text: Option<&[u8]>,
) -> Result<(), Failure> {
    let mut temp = None;
    let result = map::write(&call.paths.map, &scan.raw, n, text, &mut temp);
    lock.temps.extend(temp);
    result
}

/// Syncs under the lock, releases it, then gives `name`'s rows in check format.
fn edit_end(call: &Call, lock: Lock, name: &[u8]) -> Outcome {
    let (_, lines) = write_shims(call, lock);
    let failed = !lines.is_empty();
    for line in &lines {
        line.report(call.interactive, &call.paths.prefix);
    }
    let scan = map::scan(&call.paths.map);
    let lendk = shims::self_path(call.env, call.argv0);
    if std::fs::metadata(map::path(&call.paths.map)).is_err()
        || scan.cmds.len() + scan.groups.len() + scan.bad.len() == 0
    {
        check::empty_map_notice(call.interactive);
    }
    let out = check::rows(call.env, call.paths, &scan, &lendk, call.interactive).print(&[name]);
    Ok((out, if failed { 125 } else { 0 }))
}

fn check_words(name: &[u8], words: &[&[u8]]) -> Result<(), Ending> {
    check_name(name)?;
    let group = name.strip_prefix(b"@");
    for w in words {
        if let Some(problem) = map::bad_word(w, group) {
            return Err(usage(problem));
        }
    }
    Ok(())
}

/// `lendk add [--force] NAME WORD...`: add a map entry or words, validated first.
pub fn add(call: &Call, words: &[&[u8]]) -> Outcome {
    let force = words.first() == Some(&&b"--force"[..]);
    let words = &words[usize::from(force)..];
    let Some((&name, words)) = words.split_first().filter(|(_, w)| !w.is_empty()) else {
        return Err(usage(
            "add needs a command or @group and at least one key or @group",
        ));
    };
    check_words(name, words)?;
    let guarded = !name.starts_with(b"@") && is_guarded(name);
    if guarded && !force {
        let text = [name, b" runs other programs, so its keys reach all of them"].concat();
        return Err(Failure::new(&tables::GUARDED, text)
            .with("CMD", name)
            .into());
    }
    let map_path = &call.paths.map;
    let add_check = |scan: &Scan| {
        for w in words {
            if let Some(g) = w.strip_prefix(b"@")
                && scan.get(w).is_none()
            {
                let text = [&map_path[..], b": ", &map::not_defined(w)].concat();
                return Err(Failure::new(&tables::MAP_GROUP, text).with("GROUP", g));
            }
        }
        Ok(())
    };
    let (scan, mut lock) = edit_begin(call, &add_check)?;
    let entry = scan.get(name);
    let mut have: Vec<&[u8]> = entry
        .map(|e| e.words.iter().map(Vec::as_slice).collect())
        .unwrap_or_default();
    let mut new: Vec<&[u8]> = Vec::new();
    for w in words {
        if !have.contains(w) {
            have.push(w);
            new.push(w);
        }
    }
    match entry {
        None => {
            let line = [name, b" ", &new.join(&b' ')[..]].concat();
            edit_map(call, &scan, &mut lock, 0, Some(&line))?;
        }
        Some(e) if !new.is_empty() => {
            // The words go after the last one, before any trailing blanks and comment.
            let line = &scan.raw[e.line - 1];
            let code = line.split(|&c| c == b'#').next().unwrap_or_default();
            let trim = code.len()
                - code
                    .iter()
                    .rev()
                    .take_while(|c| **c == b' ' || **c == b'\t')
                    .count();
            let text = [&line[..trim], b" ", &new.join(&b' ')[..], &line[trim..]].concat();
            edit_map(call, &scan, &mut lock, e.line, Some(&text))?;
        }
        Some(_) => {}
    }
    if guarded {
        notice(&[name, b" runs other programs, so its keys reach all of them"].concat());
    }
    edit_end(call, lock, name)
}

/// `lendk rm NAME [WORD...]`: remove a map entry or words, validated first.
pub fn rm(call: &Call, words: &[&[u8]]) -> Outcome {
    let Some((&name, words)) = words.split_first() else {
        return Err(usage("rm needs a command or @group"));
    };
    check_words(name, words)?;
    let map_path = &call.paths.map;
    // A group rm would remove must be used by no command.
    let rm_check = |scan: &Scan| {
        let Some(g) = scan.get(name).filter(|_| name.starts_with(b"@")) else {
            return Ok(());
        };
        if !words.is_empty() && g.words.iter().any(|w| !words.contains(&&w[..])) {
            return Ok(());
        }
        for c in &scan.cmds {
            let e = scan.get(c).expect("every command has an entry");
            if e.words.iter().any(|w| w == name) {
                let text = [
                    &map_path[..],
                    format!(":{}: ", e.line).as_bytes(),
                    c,
                    b" uses group ",
                    name,
                    b", so it cannot be removed",
                ]
                .concat();
                return Err(Failure::new(&tables::MAP, text));
            }
        }
        Ok(())
    };
    let (scan, mut lock) = edit_begin(call, &rm_check)?;
    let Some(e) = scan.get(name) else {
        notice(&[name, b" is not in ", map_path, b", so nothing changed"].concat());
        return edit_end(call, lock, name);
    };
    for w in words {
        if !e.words.iter().any(|x| x == w) {
            notice(&[name, b" does not hold ", w, b", so nothing changed for it"].concat());
        }
    }
    let kept: Vec<&[u8]> = if words.is_empty() {
        Vec::new()
    } else {
        e.words
            .iter()
            .map(Vec::as_slice)
            .filter(|w| !words.contains(w))
            .collect()
    };
    if kept.is_empty() {
        edit_map(call, &scan, &mut lock, e.line, None)?;
    } else if kept.len() != e.words.len() {
        let line = &scan.raw[e.line - 1];
        let rest = line.iter().position(|&c| c == b'#').map(|i| &line[i..]);
        let mut text = [name, b" ", &kept.join(&b' ')[..]].concat();
        if let Some(rest) = rest {
            text.push(b' ');
            text.extend_from_slice(rest);
        }
        edit_map(call, &scan, &mut lock, e.line, Some(&text))?;
    }
    edit_end(call, lock, name)
}
