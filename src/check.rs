//! Check's rows: each mapped group and command with its words and its problems, in check
//! format, read from file existence only, never a value.

use crate::cli::Env;
use crate::exec;
use crate::map::{Paths, Scan, path};
use crate::pass;
use crate::shims;
use crate::sys;

/// Each name's problems, `TEXT (FIX)` joined by `; `.
pub struct Rows<'a> {
    scan: &'a Scan,
    status: Vec<(Vec<u8>, Vec<u8>)>,
}

impl Rows<'_> {
    fn add(
        &mut self,
        name: &[u8],
        text: &[u8],
        fix: &[u8],
        nfix: Option<&[u8]>,
        interactive: bool,
    ) {
        let fix = if interactive {
            fix
        } else {
            nfix.unwrap_or(b"ask the user")
        };
        let item = [text, b" (", fix, b")"].concat();
        match self.status.iter_mut().find(|(n, _)| n == name) {
            Some((_, s)) => {
                s.extend_from_slice(b"; ");
                s.extend_from_slice(&item);
            }
            None => self.status.push((name.to_vec(), item)),
        }
    }

    /// The groups, then the commands, each sorted bytewise, as `NAME\tWORDS\tSTATUS`, keeping
    /// those named in `names`, holding a key named there or using a group named there.
    pub fn print(&self, names: &[&[u8]]) -> Vec<u8> {
        let mut groups = self.scan.groups.clone();
        let mut cmds = self.scan.cmds.clone();
        groups.sort();
        cmds.sort();
        let mut out = Vec::new();
        for name in groups.iter().chain(&cmds) {
            let Some(e) = self.scan.get(name) else {
                continue;
            };
            let keep = names.is_empty()
                || names.iter().any(|n| {
                    let group = [b"@", n.strip_prefix(b"@").unwrap_or(n)].concat();
                    *n == &name[..] || e.keys.iter().any(|k| k == n) || e.words.contains(&group)
                });
            if !keep {
                continue;
            }
            let status = self.status.iter().find(|(n, _)| n == name);
            out.extend_from_slice(name);
            out.push(b'\t');
            out.extend_from_slice(&e.words.join(&b' '));
            out.push(b'\t');
            out.extend_from_slice(status.map_or(&b"ok"[..], |(_, s)| s));
            out.push(b'\n');
        }
        out
    }
}

fn on_path_dir(dir: &[u8], shims: &[u8]) -> bool {
    let dir = if dir.is_empty() { &b"."[..] } else { dir };
    dir == shims
        || (std::fs::metadata(path(dir)).is_ok_and(|m| m.is_dir()) && sys::same_file(dir, shims))
}

/// The per-name problems of check over `scan`, `lendk` being lendk's path for the shims.
pub fn rows<'a>(
    env: &Env,
    paths: &Paths,
    scan: &'a Scan,
    lendk: &[u8],
    interactive: bool,
) -> Rows<'a> {
    let mut rows = Rows {
        scan,
        status: Vec::new(),
    };
    let shims = &paths.shims[..];
    for (line, name, text) in &scan.bad {
        if !name.is_empty() {
            let text = [format!("line {line}: ").as_bytes(), text].concat();
            rows.add(name, &text, b"fix the line", None, interactive);
        }
    }
    let path_var = env.get("PATH").unwrap_or_default();
    let onpath = path_var
        .split(|&c| c == b':')
        .any(|d| on_path_dir(d, shims));
    for f in shims::files(shims) {
        let name = &f[shims.len() + 1..];
        if !shims::is_shim(&f) && scan.cmds.iter().any(|c| c == name) {
            let fix = [b"move it out of ", shims].concat();
            rows.add(
                name,
                &[&f[..], b" is not a lendk shim"].concat(),
                &fix,
                None,
                interactive,
            );
        }
    }
    let injected = env.get("LENDK_INJECTED").unwrap_or_default();
    let injected: Vec<&[u8]> = injected.split(|&c| c == b' ').collect();
    for name in scan.groups.iter().chain(&scan.cmds) {
        let Some(e) = scan.get(name) else { continue };
        for k in &e.keys {
            if !pass::has(paths, k) {
                let entry = [&paths.prefix[..], b"/", k].concat();
                let text = [&entry[..], b" is not in the store"].concat();
                rows.add(
                    name,
                    &text,
                    &[b"pass insert ", &entry[..]].concat(),
                    None,
                    interactive,
                );
            }
            if env.get(k).is_some_and(|v| !v.is_empty()) && !injected.contains(&&k[..]) {
                let text = [
                    &k[..],
                    b" is set in the environment, which overrides the store",
                ]
                .concat();
                rows.add(
                    name,
                    &text,
                    b"unset it where it is exported",
                    None,
                    interactive,
                );
            }
        }
        if name.starts_with(b"@") {
            continue;
        }
        let f = [shims, b"/", name].concat();
        let sync = Some(&b"lendk sync"[..]);
        if std::fs::symlink_metadata(path(&f)).is_err() {
            rows.add(name, b"no shim", b"lendk sync", sync, interactive);
        } else if shims::is_shim(&f) {
            let content = std::fs::read(path(&f)).unwrap_or_default();
            if content != shims::text(lendk, name) || !shims::mode_ok(&f) {
                let third = content.split(|&c| c == b'\n').nth(2).unwrap_or_default();
                let quoted = third.strip_prefix(b"lendk='").unwrap_or(third);
                let quoted = quoted.strip_suffix(b"'").unwrap_or(quoted);
                let runs = String::from_utf8_lossy(quoted)
                    .replace("'\\''", "'")
                    .into_bytes();
                let runnable = std::fs::metadata(path(&runs)).is_ok_and(|m| m.is_file())
                    && sys::executable(&runs);
                if runnable {
                    rows.add(name, b"stale shim", b"lendk sync", sync, interactive);
                } else {
                    let text =
                        [b"the shim runs ", &runs[..], b", which is not executable"].concat();
                    rows.add(name, &text, b"lendk sync", sync, interactive);
                }
            }
        }
        if let Err(failure) = exec::resolve(env, shims, name) {
            let fix = [b"install it, or unmap it: lendk rm ", &name[..]].concat();
            rows.add(name, &failure.text, &fix, None, interactive);
        }
        if !onpath {
            continue;
        }
        for dir in path_var.split(|&c| c == b':') {
            if on_path_dir(dir, shims) {
                break;
            }
            let dir = if dir.is_empty() { &b"."[..] } else { dir };
            let f = [dir, b"/", name].concat();
            if std::fs::metadata(path(&f)).is_ok_and(|m| m.is_file()) && sys::executable(&f) {
                let run = [b"lendk run -- ", &name[..]].concat();
                let fix = [b"put ", shims, b" first on PATH, or call: ", &run[..]].concat();
                rows.add(
                    name,
                    &[b"shadowed by ", &f[..]].concat(),
                    &fix,
                    Some(&run),
                    interactive,
                );
                break;
            }
        }
    }
    rows
}
