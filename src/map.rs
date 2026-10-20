//! Map: the paths from the environment, the word checks, and run's read of the map, which
//! expands one command's entry or the named words into an ordered, de-duplicated key list.

use crate::cli::Env;
use crate::failure::Failure;
use crate::sys;
use crate::tables::{DENIED_NAMES, DENIED_PREFIXES, RESERVED_CMDS};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

/// The map, shim and store paths and the entry prefix.
pub struct Paths {
    pub map: Vec<u8>,
    pub shims: Vec<u8>,
    pub store: Vec<u8>,
    pub prefix: Vec<u8>,
}

impl Paths {
    pub fn new(env: &Env) -> Self {
        let home = env.get("HOME").unwrap_or_default();
        let base = |var: &str, default: &[u8]| match env.get(var) {
            Some(v) if v.starts_with(b"/") => v.to_vec(),
            _ => [home, default].concat(),
        };
        let or = |var: &str, default: Vec<u8>| match env.get(var) {
            Some(v) if !v.is_empty() => v.to_vec(),
            _ => default,
        };
        let map = or(
            "LENDK_MAP",
            [base("XDG_CONFIG_HOME", b"/.config"), b"/lendk/map".to_vec()].concat(),
        );
        let mut shims = or(
            "LENDK_SHIMS",
            [
                base("XDG_DATA_HOME", b"/.local/share"),
                b"/lendk/shims".to_vec(),
            ]
            .concat(),
        );
        while shims.len() > 1 && shims.ends_with(b"/") {
            shims.pop();
        }
        Paths {
            map,
            shims,
            store: or("PASSWORD_STORE_DIR", [home, b"/.password-store"].concat()),
            prefix: or("LENDK_PREFIX", b"env".to_vec()),
        }
    }
}

pub fn path(bytes: &[u8]) -> &Path {
    Path::new(OsStr::from_bytes(bytes))
}

fn quoted(word: &[u8]) -> Vec<u8> {
    [b"'", word, b"'"].concat()
}

/// Why `word` is no valid KEY or @NAME, if it is not; a word of `group`'s line must be a KEY.
pub fn bad_word(word: &[u8], group: Option<&[u8]>) -> Option<Vec<u8>> {
    if let Some(name) = word.strip_prefix(b"@") {
        if let Some(g) = group {
            return Some([b"group @", g, b" holds ", word, b"; groups hold keys only"].concat());
        }
        let ok = |c: &u8| c.is_ascii_alphanumeric() || *c == b'_' || *c == b'-';
        if name.is_empty() || !name.iter().all(ok) {
            return Some([&quoted(word), &b" is not a valid group name"[..]].concat());
        }
        return None;
    }
    let first_ok = word
        .first()
        .is_some_and(|c| c.is_ascii_alphabetic() || *c == b'_');
    if !first_ok || !word.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'_') {
        return Some([&quoted(word), &b" is not a valid key name"[..]].concat());
    }
    let denied = DENIED_NAMES.iter().any(|n| n.as_bytes() == word)
        || word.to_ascii_uppercase().starts_with(b"LENDK_")
        || DENIED_PREFIXES
            .iter()
            .any(|p| word.starts_with(p.as_bytes()));
    denied.then(|| [b"key ", &quoted(word)[..], b" is denied"].concat())
}

/// The directory part of `file`: `/` for a file at the root, `.` for a bare name.
pub fn dirname(file: &[u8]) -> &[u8] {
    match file.iter().rposition(|&c| c == b'/') {
        Some(0) => b"/",
        Some(i) => &file[..i],
        None => b".",
    }
}

/// `path` with its symlinks followed, at most 40.
pub fn resolve_links(path: &[u8]) -> Vec<u8> {
    let mut resolved = path.to_vec();
    for _ in 0..40 {
        let Ok(link) = std::fs::read_link(self::path(&resolved)) else {
            break;
        };
        let link = link.as_os_str().as_bytes();
        resolved = match resolved.iter().rposition(|&c| c == b'/') {
            Some(i) if !link.starts_with(b"/") => [&resolved[..=i], link].concat(),
            _ => link.to_vec(),
        };
    }
    resolved
}

/// The owner and mode check of the map and its directory, after following a symlinked map.
pub fn check_paths(map: &[u8]) -> Result<(), Failure> {
    let file = resolve_links(map);
    if std::fs::metadata(path(&file)).is_err() {
        return Ok(());
    }
    let dir = dirname(&file).to_vec();
    let unsafe_path =
        |p: &[u8], what: &[u8]| Failure::new("unsafe", [p, what].concat()).with("PATH", p.to_vec());
    let mut metas = Vec::new();
    for p in [&dir, &file] {
        let meta = std::fs::metadata(path(p));
        if meta.as_ref().is_ok_and(|m| m.uid() != sys::euid()) {
            return Err(unsafe_path(p, b" is owned by another user"));
        }
        metas.push(meta);
    }
    for (p, meta) in [&dir, &file].into_iter().zip(metas) {
        let Ok(meta) = meta else {
            return Err(unsafe_path(&file, b" cannot be inspected"));
        };
        if meta.mode() & 0o022 != 0 {
            return Err(unsafe_path(p, b" is writable by others"));
        }
    }
    Ok(())
}

fn is_blank(c: &u8) -> bool {
    *c == b' ' || *c == b'\t'
}

/// The fields of a map line before its comment.
fn fields(line: &[u8]) -> Vec<&[u8]> {
    let line = line.split(|&c| c == b'#').next().unwrap_or_default();
    line.split(|c| is_blank(c) || *c == b'\n')
        .filter(|f| !f.is_empty())
        .collect()
}

fn at(map: &[u8], line: usize, text: &[u8]) -> Failure {
    let mut out = map.to_vec();
    if line > 0 {
        out.extend_from_slice(format!(":{line}").as_bytes());
    }
    out.extend_from_slice(b": ");
    out.extend_from_slice(text);
    Failure::new("map", out)
}

/// The first valid key word of the map, groups skipped, for which `present` holds; None when
/// the map does not exist or holds none.
pub fn first_key(map: &[u8], present: impl Fn(&[u8]) -> bool) -> Result<Option<Vec<u8>>, Failure> {
    if std::fs::metadata(path(map)).is_err() {
        return Ok(None);
    }
    let text = std::fs::read(path(map)).map_err(|_| at(map, 0, b"cannot be read"))?;
    let found = text.split(|&c| c == b'\n').find_map(|line| {
        fields(line)
            .into_iter()
            .skip(1)
            .find(|w| !w.starts_with(b"@") && bad_word(w, None).is_none() && present(w))
    });
    Ok(found.map(<[u8]>::to_vec))
}

/// The keys for `cmd`: `words` when given, else `cmd`'s entry, with groups inlined in word order
/// and duplicates dropped, keeping the first. Only the lines that `cmd` and its groups need are
/// checked.
pub fn expand_keys(map: &[u8], cmd: &[u8], words: &[&[u8]]) -> Result<Vec<Vec<u8>>, Failure> {
    let mut lines: Vec<Vec<u8>> = Vec::new();
    if words.is_empty() || words.iter().any(|w| w.starts_with(b"@")) {
        let file = path(map);
        if std::fs::symlink_metadata(file).is_ok() && std::fs::metadata(file).is_ok() {
            let text = std::fs::read(file).map_err(|_| at(map, 0, b"cannot be read"))?;
            lines = text.split(|&c| c == b'\n').map(<[u8]>::to_vec).collect();
            if text.ends_with(b"\n") {
                lines.pop();
            }
        }
    }
    let (mut cmd_line, mut cmd_dup) = (0, 0);
    let mut groups: Vec<(&[u8], usize, usize)> = Vec::new();
    for (i, raw) in lines.iter().enumerate() {
        let n = i + 1;
        let start = raw.iter().position(|c| !is_blank(c)).unwrap_or(raw.len());
        let line = &raw[start..];
        if let Some(rest) = line.strip_prefix(cmd)
            && rest.first().is_none_or(|c| is_blank(c) || *c == b'#')
        {
            if cmd_line == 0 {
                cmd_line = n;
            } else if cmd_dup == 0 {
                cmd_dup = n;
            }
        } else if let Some(rest) = line.strip_prefix(b"@")
            && rest.first().is_some_and(|c| !is_blank(c) && *c != b'#')
        {
            let end = rest
                .iter()
                .position(|c| is_blank(c) || *c == b'#')
                .unwrap_or(rest.len());
            let name = &rest[..end];
            match groups.iter_mut().find(|g| g.0 == name) {
                Some(g) if g.2 == 0 => g.2 = n,
                Some(_) => {}
                None => groups.push((name, n, 0)),
            }
        }
    }
    let mut words: Vec<&[u8]> = words.to_vec();
    let mut src = 0;
    if words.is_empty() {
        if cmd_line == 0 {
            return Err(
                Failure::new("unmapped", [cmd, b" is not mapped"].concat()).with("CMD", cmd)
            );
        }
        if cmd_dup != 0 {
            return Err(at(map, cmd_dup, &mapped_twice(cmd)));
        }
        if RESERVED_CMDS.iter().any(|r| r.as_bytes() == cmd) {
            return Err(at(map, cmd_line, &runtime(cmd)));
        }
        words = fields(&lines[cmd_line - 1]).split_off(1);
        if words.is_empty() {
            return Err(at(map, cmd_line, &[cmd, b" maps no keys"].concat()));
        }
        for word in &words {
            if let Some(problem) = bad_word(word, None) {
                return Err(at(map, cmd_line, &problem));
            }
        }
        src = cmd_line;
    }
    let mut keys: Vec<Vec<u8>> = Vec::new();
    let mut add = |key: &[u8]| {
        if !keys.iter().any(|k| k == key) {
            keys.push(key.to_vec());
        }
    };
    for word in words {
        let Some(name) = word.strip_prefix(b"@") else {
            add(word);
            continue;
        };
        let Some(&(_, line, dup)) = groups.iter().find(|g| g.0 == name) else {
            return Err(at(map, src, &not_defined(word)));
        };
        if dup != 0 {
            return Err(at(map, dup, &defined_twice(word)));
        }
        let gwords = fields(&lines[line - 1]).split_off(1);
        if gwords.is_empty() {
            return Err(at(
                map,
                line,
                &[b"group ", word, b" holds no keys"].concat(),
            ));
        }
        for key in gwords {
            if let Some(problem) = bad_word(key, Some(name)) {
                return Err(at(map, line, &problem));
            }
            add(key);
        }
    }
    Ok(keys)
}

/// The whole map, read without failing: the valid commands and groups in line order, each one's
/// line, words and expanded keys, and every violation.
#[derive(Default)]
pub struct Scan {
    pub cmds: Vec<Vec<u8>>,
    pub groups: Vec<Vec<u8>>,
    /// Each valid name's 1-based line, words and keys.
    pub entries: Vec<Entry>,
    /// Each violation as its line (0 for the whole file), the row it belongs to, and its text,
    /// in line order.
    pub bad: Vec<(usize, Vec<u8>, Vec<u8>)>,
    /// The lines as read, without their newlines.
    pub raw: Vec<Vec<u8>>,
}

pub struct Entry {
    pub name: Vec<u8>,
    pub line: usize,
    pub words: Vec<Vec<u8>>,
    pub keys: Vec<Vec<u8>>,
}

impl Scan {
    pub fn get(&self, name: &[u8]) -> Option<&Entry> {
        self.entries.iter().find(|e| e.name == name)
    }

    /// One `map` failure per violation.
    pub fn failures(&self, map: &[u8]) -> Vec<Failure> {
        self.bad
            .iter()
            .map(|(n, _, text)| at(map, *n, text))
            .collect()
    }
}

/// The map's problem texts, shared by run's read, the scan and the editing verbs.
pub fn runtime(cmd: &[u8]) -> Vec<u8> {
    [cmd, b" is lendk's own runtime and cannot be mapped"].concat()
}

pub fn invalid_cmd(cmd: &[u8]) -> Vec<u8> {
    [b"'", cmd, b"' is not a valid command name"].concat()
}

fn mapped_twice(cmd: &[u8]) -> Vec<u8> {
    [cmd, b" is mapped twice"].concat()
}

pub fn not_defined(group: &[u8]) -> Vec<u8> {
    [b"group ", group, b" is not defined"].concat()
}

fn defined_twice(group: &[u8]) -> Vec<u8> {
    [b"group ", group, b" is defined twice"].concat()
}

/// Whether `name` is a valid command name.
pub fn valid_cmd(name: &[u8]) -> bool {
    name.first()
        .is_some_and(|c| c.is_ascii_alphanumeric() || *c == b'_' || *c == b'+')
        && name
            .iter()
            .all(|c| c.is_ascii_alphanumeric() || b"._+-".contains(c))
}

/// Reads the whole map at `map`; a missing map is empty.
pub fn scan(map: &[u8]) -> Scan {
    let mut s = Scan::default();
    if std::fs::metadata(path(map)).is_ok() {
        let Ok(text) = std::fs::read(path(map)) else {
            s.bad.push((0, Vec::new(), b"cannot be read".to_vec()));
            return s;
        };
        s.raw = text.split(|&c| c == b'\n').map(<[u8]>::to_vec).collect();
        if text.is_empty() || text.ends_with(b"\n") {
            s.raw.pop();
        }
    }
    for (i, raw) in s.raw.iter().enumerate() {
        let n = i + 1;
        let f = fields(raw);
        let Some((&name, words)) = f.split_first() else {
            continue;
        };
        let mut bad = |row: &[u8], text: Vec<u8>| s.bad.push((n, row.to_vec(), text));
        if let Some(group) = name.strip_prefix(b"@") {
            if let Some(problem) = bad_word(name, None) {
                bad(b"", problem);
                continue;
            }
            if s.groups.iter().any(|g| g == name) {
                bad(name, defined_twice(name));
                continue;
            }
            s.groups.push(name.to_vec());
            if words.is_empty() {
                bad(name, [b"group ", name, b" holds no keys"].concat());
            }
            for w in words {
                if let Some(problem) = bad_word(w, Some(group)) {
                    bad(name, problem);
                }
            }
        } else {
            if !valid_cmd(name) {
                bad(b"", invalid_cmd(name));
                continue;
            }
            if RESERVED_CMDS.iter().any(|r| r.as_bytes() == name) {
                bad(b"", runtime(name));
                continue;
            }
            if s.cmds.iter().any(|c| c == name) {
                bad(name, mapped_twice(name));
                continue;
            }
            s.cmds.push(name.to_vec());
            if words.is_empty() {
                bad(name, [name, b" maps no keys"].concat());
            }
            for w in words {
                if let Some(problem) = bad_word(w, None) {
                    bad(name, problem);
                }
            }
        }
        s.entries.push(Entry {
            name: name.to_vec(),
            line: n,
            words: words.iter().map(|w| w.to_vec()).collect(),
            keys: Vec::new(),
        });
    }
    let mut keys_of = Vec::new();
    for e in &s.entries {
        let is_group = e.name.starts_with(b"@");
        let mut keys: Vec<Vec<u8>> = Vec::new();
        let mut seen: Vec<&[u8]> = Vec::new();
        for w in &e.words {
            let group_keys: Vec<&[u8]> = if w.starts_with(b"@") {
                if is_group {
                    continue;
                }
                let Some(g) = s.entries.iter().find(|g| g.name == *w) else {
                    s.bad.push((e.line, e.name.clone(), not_defined(w)));
                    continue;
                };
                g.words
                    .iter()
                    .filter(|k| bad_word(k, Some(b"x")).is_none())
                    .map(Vec::as_slice)
                    .collect()
            } else {
                if bad_word(w, None).is_some() {
                    continue;
                }
                vec![w.as_slice()]
            };
            for k in group_keys {
                if !seen.contains(&k) {
                    seen.push(k);
                    keys.push(k.to_vec());
                }
            }
        }
        keys_of.push(keys);
    }
    for (e, keys) in s.entries.iter_mut().zip(keys_of) {
        e.keys = keys;
    }
    s.bad.sort_by_key(|b| b.0);
    s
}

/// Writes the map with line `n` replaced by `text`, deleted without `text`, or `text` appended
/// when `n` is 0. The new map is a private file beside the map, after following a symlink,
/// renamed over it; `temp` names it while it exists.
pub fn write(
    map: &[u8],
    raw: &[Vec<u8>],
    n: usize,
    text: Option<&[u8]>,
    temp: &mut Option<Vec<u8>>,
) -> Result<(), Failure> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let file = resolve_links(map);
    let dir = dirname(&file).to_vec();
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path(&dir))
        .map_err(|_| {
            Failure::new("write", [&dir[..], b": cannot be created"].concat())
                .with("PATH", &dir[..])
        })?;
    let mut out = Vec::new();
    for (i, line) in raw.iter().enumerate() {
        if i + 1 != n {
            out.extend_from_slice(line);
            out.push(b'\n');
        } else if let Some(text) = text {
            out.extend_from_slice(text);
            out.push(b'\n');
        }
    }
    if n == 0 {
        out.extend_from_slice(text.unwrap_or_default());
        out.push(b'\n');
    }
    let tmp = [
        &dir[..],
        format!("/.lendk-map.{}", std::process::id()).as_bytes(),
    ]
    .concat();
    *temp = Some(tmp.clone());
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path(&tmp))
        .and_then(|mut f| f.write_all(&out))
        .and_then(|()| std::fs::rename(path(&tmp), path(&file)));
    if written.is_err() {
        let _ = std::fs::remove_file(path(&tmp));
        *temp = None;
        return Err(
            Failure::new("write", [&file[..], b": cannot be written"].concat()).with("PATH", file),
        );
    }
    *temp = None;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(f: Failure) -> String {
        String::from_utf8(f.text).unwrap()
    }

    #[test]
    fn words_are_checked_as_keys_or_groups() {
        assert_eq!(bad_word(b"K_1", None), None);
        assert_eq!(bad_word(b"@g-1", None), None);
        let problem =
            |w: &[u8], g: Option<&[u8]>| String::from_utf8(bad_word(w, g).unwrap()).unwrap();
        assert_eq!(problem(b"1BAD", None), "'1BAD' is not a valid key name");
        assert_eq!(problem(b"@", None), "'@' is not a valid group name");
        assert_eq!(problem(b"PATH", None), "key 'PATH' is denied");
        assert_eq!(problem(b"lendk_x", None), "key 'lendk_x' is denied");
        assert_eq!(problem(b"LC_ALL", None), "key 'LC_ALL' is denied");
        assert_eq!(
            problem(b"@h", Some(b"g")),
            "group @g holds @h; groups hold keys only"
        );
    }

    fn map_file(lines: &str) -> (std::path::PathBuf, Vec<u8>) {
        let dir = std::env::temp_dir().join(format!(
            "lendk-map-test-{}-{}",
            std::process::id(),
            lines.len()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("map");
        std::fs::write(&file, lines).unwrap();
        let bytes = file.as_os_str().as_bytes().to_vec();
        (dir, bytes)
    }

    #[test]
    fn groups_expand_in_word_order_and_duplicates_drop_keeping_the_first() {
        let (dir, map) = map_file("  stub K2 @g K1 # @late\n@g K1 K2 K3\nother PATH\n");
        let keys = expand_keys(&map, b"stub", &[]).unwrap();
        assert_eq!(keys, [b"K2".to_vec(), b"K1".to_vec(), b"K3".to_vec()]);
        let keys = expand_keys(&map, b"x", &[b"K3", b"@g", b"K3"]).unwrap();
        assert_eq!(keys, [b"K3".to_vec(), b"K1".to_vec(), b"K2".to_vec()]);
        let err = expand_keys(&map, b"nope", &[]).unwrap_err();
        assert_eq!(err.id, "unmapped");
        let err = expand_keys(&map, b"x", &[b"@none"]).unwrap_err();
        assert_eq!(
            text(err),
            format!(
                "{}: group @none is not defined",
                String::from_utf8_lossy(&map)
            )
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn scan_reports_every_violation_in_line_then_word_order_and_keeps_valid_entries() {
        let (dir, map) = map_file("stub PATH 9x @nope HOME\n'x\nbad! K\n@g K1\n@g K2\nok K1 @g\n");
        let scan = scan(&map);
        let texts: Vec<(usize, String)> = scan
            .bad
            .iter()
            .map(|(n, _, t)| (*n, String::from_utf8(t.clone()).unwrap()))
            .collect();
        let want = [
            (1, "key 'PATH' is denied"),
            (1, "'9x' is not a valid key name"),
            (1, "key 'HOME' is denied"),
            (1, "group @nope is not defined"),
            (2, "''x' is not a valid command name"),
            (3, "'bad!' is not a valid command name"),
            (5, "group @g is defined twice"),
        ];
        let want: Vec<(usize, String)> = want.iter().map(|(n, t)| (*n, t.to_string())).collect();
        assert_eq!(texts, want);
        assert_eq!(scan.cmds, [b"stub".to_vec(), b"ok".to_vec()]);
        assert_eq!(scan.get(b"ok").unwrap().keys, [b"K1".to_vec()]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_write_changes_only_its_line_and_leaves_a_private_map() {
        let (dir, map) = map_file("a K\r\n# c\nb K # n\n");
        let raw = scan(&map).raw;
        let mut temp = None;
        write(&map, &raw, 3, Some(b"b K J # n"), &mut temp).unwrap();
        assert_eq!(
            std::fs::read(path(&map)).unwrap(),
            b"a K\r\n# c\nb K J # n\n"
        );
        assert_eq!(std::fs::metadata(path(&map)).unwrap().mode() & 0o777, 0o600);
        write(&map, &raw, 1, None, &mut temp).unwrap();
        assert_eq!(std::fs::read(path(&map)).unwrap(), b"# c\nb K # n\n");
        assert_eq!(temp, None);
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
