//! `lendk upgrade`: replace lendk with the latest release's archive for its platform, after the
//! four checks of #28, then run `sync` through the new file.

use crate::cli::Env;
use crate::failure::Failure;
use crate::helpers::{self, Watchdog};
use crate::map::{Paths, path};
use crate::pass::{self, TempDir};
use crate::shims;
use crate::sys;
use crate::tables::VERSION;
use std::ffi::{CString, c_char};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::time::{Duration, Instant};

/// The marker a new lendk carries, in one static so its bytes sit together in the file.
#[used]
pub static MARKER: [u8; 62] = *b"lendk binary v1: give API keys to the commands mapped to them.";

const DEFAULT_BASE: &[u8] = b"https://github.com/v-bonilla/lendk/releases";

/// The release platform of a build for `os` and `arch`, as Rust names them: Linux maps to its
/// static musl target whatever libc built lendk, macOS to its Apple target.
pub fn platform_for(os: &str, arch: &str) -> Option<String> {
    let rest = match os {
        "linux" => "unknown-linux-musl",
        "macos" => "apple-darwin",
        _ => return None,
    };
    matches!(arch, "x86_64" | "aarch64").then(|| format!("{arch}-{rest}"))
}

/// The platform this build upgrades to, from its compile-time OS and architecture, never uname.
/// A build no release ships for gets a name no `SHA256SUMS` lists.
fn platform() -> String {
    use std::env::consts::{ARCH, OS};
    platform_for(OS, ARCH).unwrap_or_else(|| format!("{ARCH}-{OS}"))
}

/// A release's X.Y.Z: numbers of at most nine digits with no leading zero, so they compare
/// without overflow.
pub fn parse_version(v: &[u8]) -> Option<[u32; 3]> {
    let mut out = [0u32; 3];
    let mut parts = v.split(|&c| c == b'.');
    for slot in &mut out {
        let p = parts.next()?;
        if p.is_empty() || p.len() > 9 || !p.iter().all(u8::is_ascii_digit) {
            return None;
        }
        if p.len() > 1 && p[0] == b'0' {
            return None;
        }
        *slot = std::str::from_utf8(p).ok()?.parse().ok()?;
    }
    parts.next().is_none().then_some(out)
}

/// The SHA-256 a `SHA256SUMS` line lists for `asset`: 64 lowercase hex digits, one or more
/// spaces, an optional `*`, then the name.
fn listed<'a>(line: &'a [u8], asset: &[u8]) -> Option<&'a [u8]> {
    let hash = line.get(..64)?;
    if !hash
        .iter()
        .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(c))
    {
        return None;
    }
    let rest = line.get(64..)?;
    let name = rest.strip_prefix(b" ")?;
    let name = &name[name.iter().take_while(|&&c| c == b' ').count()..];
    let name = name.strip_prefix(b"*").unwrap_or(name);
    (name == asset).then_some(hash)
}

/// The members named `lendk-X.Y.Z/bin/lendk` in a `tar -t` listing.
fn members(list: &[u8]) -> Vec<&[u8]> {
    list.split(|&c| c == b'\n')
        .filter(|m| {
            m.strip_prefix(b"lendk-")
                .and_then(|r| r.strip_suffix(b"/bin/lendk"))
                .is_some_and(|v| parse_version(v).is_some())
        })
        .collect()
}

/// The version a `--version` output names, when it is exactly `lendk X.Y.Z`.
fn printed_version(out: &[u8]) -> Option<&[u8]> {
    let v = out
        .strip_suffix(b"\n")
        .unwrap_or(out)
        .strip_prefix(b"lendk ")?;
    parse_version(v).map(|_| v)
}

fn shown(value: &[u8]) -> Vec<u8> {
    value
        .iter()
        .map(|&c| if c.is_ascii_graphic() { c } else { b'?' })
        .collect()
}

/// A test hook: pauses for LENDK_TEST_PAUSE seconds at `point`, which LENDK_TEST_AT names:
/// `self` before the inode check, `start` once both files exist, `rename` (the default) once
/// the new file is staged.
fn pause(env: &Env, point: &[u8]) {
    if env.get("LENDK_TEST_AT").unwrap_or(b"rename") == point
        && let Some(&[n @ b'0'..=b'9']) = env.get("LENDK_TEST_PAUSE")
    {
        std::thread::sleep(Duration::from_secs(u64::from(n - b'0')));
    }
}

/// Whether `me` is a regular file and the running binary's own: the same device and inode.
fn own_file(me: &[u8]) -> bool {
    match (
        std::fs::symlink_metadata(path(me)),
        std::fs::metadata("/proc/self/exe"),
    ) {
        (Ok(file), Ok(exe)) => file.is_file() && file.dev() == exe.dev() && file.ino() == exe.ino(),
        _ => false,
    }
}

/// The call's two files, the temporary directory and the staged file beside lendk, under the
/// watchdog that removes them if lendk is killed. On drop lendk removes them while the watchdog
/// still runs, then tells it the call is done.
struct Files {
    staged: Vec<u8>,
    tmp: TempDir,
    watchdog: Watchdog,
}

impl Drop for Files {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(path(&self.staged));
    }
}

impl Files {
    /// Creates both files and starts the watchdog with HUP, INT and TERM held, so such a signal
    /// finds the watchdog in place.
    fn create(tmp_base: &[u8], dir: &[u8]) -> Result<Files, Failure> {
        sys::hold_signals(true);
        let made = (|| {
            let tmp = sys::mkdtemp(&[tmp_base, b"/lendk.XXXXXX"].concat()).map_err(|_| {
                Failure::new(
                    "upgrade:local",
                    [tmp_base, b": cannot create a temporary directory"].concat(),
                )
            })?;
            let tmp = TempDir(tmp);
            let cannot = || Failure::new("upgrade:install", [dir, b" cannot be written"].concat());
            // Closed before the watchdog forks, so no descriptor writes the file it runs.
            let (staged, _) =
                sys::mkstemp(&[dir, b"/.lendk.XXXXXX"].concat()).map_err(|_| cannot())?;
            let watchdog = match Watchdog::start(&tmp.0, Some(&staged)) {
                Ok(w) => w,
                Err(_) => {
                    let _ = std::fs::remove_file(path(&staged));
                    return Err(cannot());
                }
            };
            Ok(Files {
                staged,
                tmp,
                watchdog,
            })
        })();
        sys::hold_signals(false);
        made
    }
}

/// The tools' runs, each a helper under the watchdog, all within one deadline.
struct Fetch<'a> {
    files: &'a Files,
    deadline: Instant,
    timeout: u64,
}

impl Fetch<'_> {
    fn file(&self, name: &[u8]) -> Vec<u8> {
        [&self.files.tmp.0[..], b"/", name].concat()
    }

    /// Runs `program` with `args` and `vars`, stdout into the temporary file `out` or
    /// /dev/null: whether it exited 0. Past the deadline its group ends and the fetch fails.
    fn run(
        &self,
        program: &[u8],
        args: &[&[u8]],
        vars: &[(Vec<u8>, Vec<u8>)],
        out: Option<&[u8]>,
    ) -> Result<bool, Failure> {
        let stdout = match out {
            Some(name) => match std::fs::File::create(path(&self.file(name))) {
                Ok(f) => Some(f),
                Err(_) => return Ok(false),
            },
            None => None,
        };
        let null = std::fs::File::create("/dev/null").ok();
        let Ok(mut job) =
            self.files
                .watchdog
                .spawn(program, args, vars, (stdout.or(null), None), None)
        else {
            return Ok(false);
        };
        job.wait(self.deadline).ok_or_else(|| {
            Failure::new(
                "upgrade",
                format!(
                    "fetching the release did not finish within {} s",
                    self.timeout
                ),
            )
        })
    }

    fn read(&self, name: &[u8]) -> Vec<u8> {
        std::fs::read(path(&self.file(name))).unwrap_or_default()
    }
}

// lint: network begin
/// The download tool on `upath`: curl, else wget, else the name of the one missing.
fn download_tool(upath: &[u8]) -> Result<Vec<u8>, &'static [u8]> {
    pass::find(upath, b"curl")
        .or_else(|| pass::find(upath, b"wget"))
        .ok_or(b"curl")
}

/// Fetches the https `url` to the temporary file `name` with `dl`: whether it succeeded.
fn download(
    fetch: &Fetch,
    dl: &[u8],
    vars: &[(Vec<u8>, Vec<u8>)],
    url: &[u8],
    name: &[u8],
) -> Result<bool, Failure> {
    let out = fetch.file(name);
    if dl.ends_with(b"/curl") {
        let args: [&[u8]; 7] = [
            b"-fsSL",
            b"--proto",
            b"=https",
            b"--tlsv1.2",
            b"-o",
            &out,
            url,
        ];
        return fetch.run(dl, &args, vars, None);
    }
    fetch.run(dl, &[b"--help"], vars, Some(b"help"))?;
    let help = fetch.read(b"help");
    if help.windows(12).any(|w| w == b"--https-only") {
        fetch.run(dl, &[b"-q", b"--https-only", b"-O", &out, url], vars, None)
    } else {
        fetch.run(dl, &[b"-q", b"-O", &out, url], vars, None)
    }
}
// lint: network end

/// `lendk upgrade`: the latest release's lendk for this platform, checked and renamed over the
/// running lendk's file, then its `sync`. It returns the up-to-date line, or the failure; after
/// a rename it returns only when the new file cannot run.
pub fn upgrade(
    env: &Env,
    paths: &Paths,
    timeout: u64,
    argv0: &[u8],
    words: &[&[u8]],
) -> Result<Vec<u8>, Failure> {
    if !words.is_empty() {
        return Err(Failure::new("usage", "upgrade takes no arguments"));
    }
    let set = env.get("LENDK_INSTALL_BASE_URL").filter(|b| !b.is_empty());
    let base = match set {
        None => DEFAULT_BASE,
        Some(b)
            if (b.starts_with(b"https://") || b.starts_with(b"file:///"))
                && !b.iter().any(|&c| c <= b' ' || c == 0x7f) =>
        {
            b
        }
        Some(b) => {
            return Err(Failure::new(
                "usage",
                [
                    &b"LENDK_INSTALL_BASE_URL is '"[..],
                    &shown(b),
                    b"'; use an https:// or file:/// URL",
                ]
                .concat(),
            ));
        }
    };
    let me = shims::self_path(env, argv0);
    let dir = match me.iter().rposition(|&c| c == b'/') {
        Some(0) | None => b"/".to_vec(),
        Some(i) => me[..i].to_vec(),
    };
    let install = |text: &[u8]| Failure::new("upgrade:install", [&me[..], text].concat());
    if std::fs::symlink_metadata(path(&me)).is_ok_and(|m| m.is_symlink()) {
        return Err(install(
            b" is a symlink, so another tool manages this install",
        ));
    }
    pause(env, b"self");
    if !own_file(&me) {
        return Err(install(b" is not lendk's own file"));
    }
    let running = parse_version(VERSION.as_bytes()).ok_or_else(|| {
        install(
            &[
                &b" has version "[..],
                &shown(VERSION.as_bytes()),
                b", not a release's X.Y.Z",
            ]
            .concat(),
        )
    })?;
    let cannot_write = || {
        Failure::new(
            "upgrade:install",
            [&dir[..], b" cannot be written"].concat(),
        )
    };
    if !sys::writable(&dir) {
        return Err(cannot_write());
    }
    let upath = helpers::path_without(env, &paths.shims);
    let missing = |name: &[u8]| {
        Failure::new(
            "upgrade:local",
            [name, b" is not on PATH outside ", &paths.shims].concat(),
        )
    };
    let tar = pass::find(&upath, b"tar").ok_or_else(|| missing(b"tar"))?;
    let gzip = pass::find(&upath, b"gzip").ok_or_else(|| missing(b"gzip"))?;
    let sha = pass::find(&upath, b"sha256sum")
        .or_else(|| pass::find(&upath, b"shasum"))
        .ok_or_else(|| missing(b"sha256sum"))?;
    let dl = if base.starts_with(b"https://") {
        Some(download_tool(&upath).map_err(missing)?)
    } else {
        None
    };
    if set.is_some() {
        let mut notice = b"lendk: notice: the release comes from ".to_vec();
        notice.extend_from_slice(base);
        notice.extend_from_slice(b", set by LENDK_INSTALL_BASE_URL.\n");
        let _ = std::io::stderr().write_all(&notice);
    }
    let tmp_base = env
        .get("TMPDIR")
        .filter(|t| !t.is_empty())
        .unwrap_or(b"/tmp");
    let files = Files::create(tmp_base, &dir)?;
    pause(env, b"start");
    let fetch = Fetch {
        files: &files,
        deadline: Instant::now() + Duration::from_secs(timeout),
        timeout,
    };
    // The tools keep the caller's environment with PATH past the shims, as in 1.x (#26); the
    // staged lendk gets the allowlist (ADR 0006).
    let mut tool_vars = vec![(b"PATH".to_vec(), upath.clone())];
    tool_vars.extend(
        env.entries()
            .filter(|(n, _)| *n != b"PATH")
            .map(|(n, v)| (n.to_vec(), v.to_vec())),
    );
    let platform = platform();
    let asset = format!("lendk-{platform}.tar.gz").into_bytes();
    let get = |name: &[u8]| -> Result<(), Failure> {
        let url = [base, b"/latest/download/", name].concat();
        let ok = match (url.strip_prefix(b"file://"), &dl) {
            (Some(local), _) => std::fs::copy(path(local), path(&fetch.file(name))).is_ok(),
            (None, Some(dl)) => download(&fetch, dl, &tool_vars, &url, name)?,
            (None, None) => false,
        };
        if ok {
            Ok(())
        } else {
            Err(Failure::new(
                "upgrade",
                [&b"cannot download "[..], &url].concat(),
            ))
        }
    };
    get(b"SHA256SUMS")?;
    let sums = fetch.read(b"SHA256SUMS");
    let want = sums
        .split(|&c| c == b'\n')
        .filter_map(|l| listed(l, &asset))
        .next_back()
        .map(<[u8]>::to_vec)
        .ok_or_else(|| {
            Failure::new(
                "upgrade:install",
                format!("the latest release has no archive for {platform}"),
            )
        })?;
    get(&asset)?;
    let archive = fetch.file(&asset);
    let sha_args: Vec<&[u8]> = if sha.ends_with(b"/shasum") {
        vec![b"-a", b"256", &archive]
    } else {
        vec![&archive]
    };
    fetch.run(&sha, &sha_args, &tool_vars, Some(b"sum"))?;
    let out = fetch.read(b"sum");
    let got = out
        .split(|&c| c == b' ' || c == b'\n')
        .next()
        .unwrap_or_default();
    if got.len() != 64
        || !got
            .iter()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(c))
    {
        return Err(Failure::new(
            "upgrade:local",
            [&sha[..], b": cannot compute a SHA-256"].concat(),
        ));
    }
    if got != want {
        return Err(Failure::new(
            "upgrade",
            [
                &asset[..],
                b" has SHA-256 ",
                got,
                b", but SHA256SUMS lists ",
                &want,
            ]
            .concat(),
        ));
    }
    let unpack = || {
        Failure::new(
            "upgrade:local",
            [tmp_base, b": cannot unpack ", &asset].concat(),
        )
    };
    let tarball = fetch.file(b"lendk.tar");
    if !fetch.run(&gzip, &[b"-dc", &archive], &tool_vars, Some(b"lendk.tar"))?
        || !fetch.run(&tar, &[b"-tf", &tarball], &tool_vars, Some(b"list"))?
    {
        return Err(unpack());
    }
    let list = fetch.read(b"list");
    let holds_no = |v: &[u8]| {
        Failure::new(
            "upgrade",
            [&asset[..], b" holds no lendk-", v, b"/bin/lendk"].concat(),
        )
    };
    let found = members(&list);
    let [member] = found[..] else {
        return Err(holds_no(b"X.Y.Z"));
    };
    if !fetch.run(
        &tar,
        &[b"-xOf", &tarball, member],
        &tool_vars,
        Some(b"lendk"),
    )? {
        return Err(unpack());
    }
    let new = fetch.read(b"lendk");
    if !new.windows(MARKER.len()).any(|w| w == MARKER) {
        return Err(holds_no(b"X.Y.Z"));
    }
    std::fs::write(path(&files.staged), &new)
        .and_then(|()| {
            std::fs::set_permissions(path(&files.staged), std::fs::Permissions::from_mode(0o755))
        })
        .map_err(|_| cannot_write())?;
    let vars = helpers::helper_env(env, &paths.shims, &[]);
    let ran = fetch.run(&files.staged, &[b"--version"], &vars, Some(b"version"))?;
    let printed = fetch.read(b"version");
    let new_version = match printed_version(&printed) {
        Some(v) if ran => v.to_vec(),
        _ => {
            return Err(Failure::new(
                "upgrade",
                format!("the downloaded lendk does not run on {platform}"),
            ));
        }
    };
    if member != [&b"lendk-"[..], &new_version, b"/bin/lendk"].concat() {
        return Err(holds_no(&new_version));
    }
    let shown_new = String::from_utf8_lossy(&new_version).into_owned();
    if parse_version(&new_version).is_none_or(|v| v <= running) {
        return Ok(
            format!("lendk {VERSION} is up to date: the latest release is {shown_new}\n")
                .into_bytes(),
        );
    }
    pause(env, b"rename");
    std::fs::rename(path(&files.staged), path(&me)).map_err(|_| cannot_write())?;
    drop(files);
    let mut line = format!("upgraded lendk {VERSION} to {shown_new} at ").into_bytes();
    line.extend_from_slice(&me);
    line.push(b'\n');
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(&line).and_then(|()| stdout.flush());
    drop(stdout);
    let Ok(me0) = CString::new(me.clone()) else {
        return Err(install(b" does not run"));
    };
    let envp: Vec<*const c_char> = env.raw().iter().map(|e| e.as_ptr()).collect();
    let _error = sys::execve(&me, &[&me0, c"sync"], &envp);
    Err(install(b" does not run"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linux_builds_upgrade_to_the_musl_archive_and_macos_to_the_apple_one() {
        assert_eq!(
            platform_for("linux", "x86_64").as_deref(),
            Some("x86_64-unknown-linux-musl")
        );
        assert_eq!(
            platform_for("linux", "aarch64").as_deref(),
            Some("aarch64-unknown-linux-musl")
        );
        assert_eq!(
            platform_for("macos", "aarch64").as_deref(),
            Some("aarch64-apple-darwin")
        );
        assert_eq!(
            platform_for("macos", "x86_64").as_deref(),
            Some("x86_64-apple-darwin")
        );
        assert_eq!(platform_for("linux", "arm"), None);
        assert_eq!(platform_for("freebsd", "x86_64"), None);
    }

    #[test]
    fn versions_compare_number_by_number_without_leading_zeros_or_overflow() {
        assert!(parse_version(b"10.0.0") > parse_version(b"9.9.9"));
        assert!(parse_version(b"1.10.0") > parse_version(b"1.9.0"));
        assert_eq!(parse_version(b"999999999.0.0"), Some([999_999_999, 0, 0]));
        for bad in [
            &b"01.0.0"[..],
            b"1.00.0",
            b"1.0",
            b"1.0.0.0",
            b"1.1.0-dev",
            b"9999999999.0.0",
            b"",
        ] {
            assert_eq!(parse_version(bad), None, "{}", String::from_utf8_lossy(bad));
        }
    }

    #[test]
    fn the_running_version_is_a_release_x_y_z() {
        assert!(parse_version(VERSION.as_bytes()).is_some());
    }

    #[test]
    fn a_sha256sums_line_names_the_asset_after_spaces_and_an_optional_star() {
        let hash = "a".repeat(64);
        let line = |s: String| listed(s.as_bytes(), b"lendk-x.tar.gz").map(<[u8]>::to_vec);
        assert_eq!(
            line(format!("{hash}  lendk-x.tar.gz")),
            Some(hash.clone().into_bytes())
        );
        assert_eq!(
            line(format!("{hash} *lendk-x.tar.gz")),
            Some(hash.clone().into_bytes())
        );
        assert_eq!(line(format!("{hash}  other.tar.gz")), None);
        assert_eq!(line(format!("{hash}lendk-x.tar.gz")), None);
        assert_eq!(line(format!("{}  lendk-x.tar.gz", "A".repeat(64))), None);
    }

    #[test]
    fn only_members_named_lendk_x_y_z_bin_lendk_count() {
        let list = b"lendk-1.2.3/\nlendk-1.2.3/bin/lendk\nlendk-01.2.3/bin/lendk\nlendk-1.2.3/bin/lendk/\nx/lendk-1.2.3/bin/lendk\n";
        assert_eq!(members(list), vec![&b"lendk-1.2.3/bin/lendk"[..]]);
    }

    #[test]
    fn the_version_output_is_exactly_lendk_x_y_z() {
        assert_eq!(printed_version(b"lendk 99.0.0\n"), Some(&b"99.0.0"[..]));
        for bad in [
            &b"x lendk 99.0.0\n"[..],
            b"lendk 99.0.0 x\n",
            b"lendk 99.0.0\nmore\n",
            b"lendk 099.0.0\n",
            b"",
        ] {
            assert_eq!(printed_version(bad), None);
        }
    }
}
