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
    let dir = match file.iter().rposition(|&c| c == b'/') {
        Some(0) => b"/".to_vec(),
        Some(i) => file[..i].to_vec(),
        None => b".".to_vec(),
    };
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
            return Err(at(map, cmd_dup, &[cmd, b" is mapped twice"].concat()));
        }
        if RESERVED_CMDS.iter().any(|r| r.as_bytes() == cmd) {
            let text = [cmd, b" is lendk's own runtime and cannot be mapped"].concat();
            return Err(at(map, cmd_line, &text));
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
            return Err(at(
                map,
                src,
                &[b"group ", word, b" is not defined"].concat(),
            ));
        };
        if dup != 0 {
            return Err(at(
                map,
                dup,
                &[b"group ", word, b" is defined twice"].concat(),
            ));
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
}
