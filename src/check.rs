//! Check's rows: each mapped group and command with its words and its problems, in check
//! format, read from file existence only, never a value.

use crate::cli::{self, Env};
use crate::edit::{Call, Outcome};
use crate::exec;
use crate::failure::{self, Failure};
use crate::map::{self, Paths, Scan, path};
use crate::pass;
use crate::shims;
use crate::sys;

/// A problem as `TEXT (FIX)`; NFIX replaces FIX in a non-interactive call, `ask the user` by
/// default (ADR 0012).
fn item(text: &[u8], fix: &[u8], nfix: Option<&[u8]>, interactive: bool) -> Vec<u8> {
    let fix = if interactive {
        fix
    } else {
        nfix.unwrap_or(b"ask the user")
    };
    [text, b" (", fix, b")"].concat()
}

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
        let item = item(text, fix, nfix, interactive);
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
                let runs = shims::runs(&content);
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
        for (dir, f) in exec::path_files(path_var, name) {
            if on_path_dir(dir, shims) {
                break;
            }
            if exec::is_executable(&f) {
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

/// The problems no row holds, in check's order: the map's and the shim directory's owner and
/// mode, map violations outside a row, the shim directory off PATH, the GnuPG floor, then stray
/// shims and foreign files of unmapped names.
fn globals(call: &Call, scan: &Scan) -> Vec<Vec<u8>> {
    let (env, paths, interactive) = (call.env, call.paths, call.interactive);
    let shims = &paths.shims[..];
    let mut out = Vec::new();
    let mut add = |text: &[u8], fix: &[u8], nfix: Option<&[u8]>| {
        out.push(item(text, fix, nfix, interactive));
    };
    if let Err(f) = map::check_paths(&paths.map) {
        add(&f.text, b"chmod go-w it, or recreate it as your own", None);
    }
    if let Err(f) = shims::check_dir(shims) {
        let fix = [b"chmod go-w ", shims, b", or recreate it as your own"].concat();
        add(&f.text, &fix, None);
    }
    for (line, name, text) in &scan.bad {
        if !name.is_empty() {
            continue;
        }
        if *line > 0 {
            let text = [&paths.map[..], format!(":{line}: ").as_bytes(), text].concat();
            add(&text, b"fix the line", None);
        } else {
            let text = [&paths.map[..], b": ", text].concat();
            add(&text, b"fix its permissions", None);
        }
    }
    let path_var = env.get("PATH").unwrap_or_default();
    if !path_var
        .split(|&c| c == b':')
        .any(|d| on_path_dir(d, shims))
    {
        add(
            &[shims, b" is not on PATH"].concat(),
            b"set up PATH: lendk init sh >> ~/.profile, then log in again",
            None,
        );
    }
    if let Err(f) = pass::gnupg(env, paths, cli::timeout(env, interactive)) {
        add(&f.text, b"upgrade GnuPG", None);
    }
    for f in shims::files(shims) {
        let name = &f[shims.len() + 1..];
        if scan.cmds.iter().any(|c| c == name) {
            continue;
        }
        if shims::is_shim(&f) {
            let sync = Some(&b"lendk sync"[..]);
            add(&[&f[..], b" is a stray shim"].concat(), b"lendk sync", sync);
        } else {
            let fix = [b"move it out of ", shims].concat();
            add(&[&f[..], b" is not a lendk shim"].concat(), &fix, None);
        }
    }
    out
}

/// The notice for a map with no command, with the next step for the call's mode.
pub fn empty_map_notice(interactive: bool) {
    let next: &[u8] = if interactive {
        b"map one with lendk add CMD KEY"
    } else {
        b"ask the user which commands to map"
    };
    failure::notice(
        &[
            &b"no command is mapped yet, so lendk gives no keys; "[..],
            next,
        ]
        .concat(),
    );
}

/// `lendk check [NAME...]`: the headers, the problems no row holds, then the rows; exit 1 only
/// when a shown item has a problem.
pub fn check(call: &Call, names: &[&[u8]]) -> Outcome {
    let paths = call.paths;
    let scan = map::scan(&paths.map);
    if scan.cmds.is_empty() && scan.groups.is_empty() && scan.bad.is_empty() {
        empty_map_notice(call.interactive);
    }
    let global = globals(call, &scan);
    let lendk = shims::self_path(call.env, call.argv0);
    let rows = rows(call.env, paths, &scan, &lendk, call.interactive);
    let mut out = [
        &b"# map: "[..],
        &paths.map,
        b"\n# shims: ",
        &paths.shims,
        b"\n# store: ",
        &paths.store,
        b"/",
        &paths.prefix,
        b"\n",
    ]
    .concat();
    for p in &global {
        out.extend_from_slice(&[b"# problem: ", &p[..], b"\n"].concat());
    }
    let shown = rows.print(names);
    let bad = !global.is_empty()
        || shown
            .split(|&c| c == b'\n')
            .filter_map(|r| r.rsplit(|&c| c == b'\t').next())
            .any(|s| !s.is_empty() && s != b"ok");
    out.extend_from_slice(&shown);
    Ok((out, i32::from(bad)))
}

/// `lendk init sh|bash|zsh|systemd`: the login block holding the absolute shim directory. It
/// reads no map, and prints no code for a shim directory open to others.
pub fn init(call: &Call, words: &[&[u8]]) -> Outcome {
    let [shell] = words else {
        return Err(Failure::new("usage", "init takes one of sh, bash, zsh or systemd").into());
    };
    if ![&b"sh"[..], b"bash", b"zsh", b"systemd"].contains(shell) {
        let text = [
            b"init takes one of sh, bash, zsh or systemd, not '",
            *shell,
            b"'",
        ]
        .concat();
        return Err(Failure::new("usage", text).into());
    }
    let shims = &call.paths.shims;
    let dir = if shims.starts_with(b"/") {
        shims.clone()
    } else {
        shims::absolute(call.env, shims)
    };
    shims::check_dir(&dir)?;
    let block = |body: &[u8]| [b"# >>> lendk >>>\n", body, b"\n# <<< lendk <<<\n"].concat();
    if *shell == b"systemd" {
        return Ok((block(&[b"PATH=", &dir[..], b":${PATH}"].concat()), 0));
    }
    let mut q = b"'".to_vec();
    for &c in &dir {
        if c == b'\'' {
            q.extend_from_slice(b"'\\''");
        } else {
            q.push(c);
        }
    }
    q.push(b'\'');
    // The loop keeps every other entry, empty ones included, in order.
    let front = [
        &b"lendk_p=; lendk_r=${PATH:+$PATH:}\nwhile [ -n \"$lendk_r\" ]; do\n\tlendk_d=${lendk_r%%:*}; lendk_r=${lendk_r#*:}\n\t[ \"$lendk_d\" = "[..],
        &q,
        b" ] || lendk_p=$lendk_p:$lendk_d\ndone\nPATH=",
        &q,
        b"$lendk_p; export PATH\nunset lendk_p lendk_r lendk_d",
    ]
    .concat();
    let (head, tail): (&[u8], &[u8]) = match *shell {
        b"bash" => (
            b"__lendk_path() {\n",
            b"\nhash -r\n}\n__lendk_path\ncase \";${PROMPT_COMMAND-};\" in *\";__lendk_path;\"*) ;; *) PROMPT_COMMAND=\"__lendk_path${PROMPT_COMMAND:+;$PROMPT_COMMAND}\" ;; esac",
        ),
        b"zsh" => (
            b"__lendk_path() {\n",
            b"\nrehash\n}\n__lendk_path\n(( ${+precmd_functions} )) || typeset -ga precmd_functions; (( ${precmd_functions[(Ie)__lendk_path]} )) || precmd_functions+=(__lendk_path)",
        ),
        _ => (b"", b""),
    };
    Ok((block(&[head, &front, tail].concat()), 0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn an_agent_gets_ask_the_user_unless_the_problem_names_its_own_fix() {
        assert_eq!(
            item(b"no shim", b"lendk sync", None, true),
            b"no shim (lendk sync)"
        );
        assert_eq!(
            item(b"x", b"pass insert env/K", None, false),
            b"x (ask the user)"
        );
        let run = Some(&b"lendk run -- gh"[..]);
        assert_eq!(
            item(b"x", b"put it first", run, false),
            b"x (lendk run -- gh)"
        );
    }

    fn init_with(shims: &'static CStr, shell: &[u8]) -> Vec<u8> {
        let entries = [shims, c"HOME=/nonexistent"];
        let env = Env(&entries);
        let paths = Paths::new(&env);
        let call = Call {
            env: &env,
            paths: &paths,
            interactive: false,
            argv0: b"lendk",
        };
        let Ok((out, 0)) = init(&call, &[shell]) else {
            panic!("init failed");
        };
        out
    }

    #[test]
    fn init_quotes_the_shim_directory_for_sh_and_leaves_systemd_unquoted() {
        let sh = "# >>> lendk >>>
lendk_p=; lendk_r=${PATH:+$PATH:}
while [ -n \"$lendk_r\" ]; do
\tlendk_d=${lendk_r%%:*}; lendk_r=${lendk_r#*:}
\t[ \"$lendk_d\" = '/nonexistent/it'\\''s' ] || lendk_p=$lendk_p:$lendk_d
done
PATH='/nonexistent/it'\\''s'$lendk_p; export PATH
unset lendk_p lendk_r lendk_d
# <<< lendk <<<
";
        let shims = c"LENDK_SHIMS=/nonexistent/it's";
        assert_eq!(String::from_utf8_lossy(&init_with(shims, b"sh")), sh);
        assert_eq!(
            init_with(shims, b"systemd"),
            b"# >>> lendk >>>\nPATH=/nonexistent/it's:${PATH}\n# <<< lendk <<<\n"
        );
    }
}
