//! The command line: `--help`, `--version`, and usage for anything else until a verb is ported.

use crate::failure::Failure;
use crate::map::Paths;
use crate::run;
use crate::sys;
use crate::tables;
use std::ffi::CStr;
use std::io::Write;

/// The environment lendk was started with: exec's own strings, never copied.
pub struct Env<'a>(&'a [&'static CStr]);

impl Env<'_> {
    /// The value of the first `NAME=` entry, as getenv finds it.
    pub fn get(&self, name: impl AsRef<[u8]>) -> Option<&'static [u8]> {
        let name = name.as_ref();
        self.0.iter().find_map(|entry| {
            entry
                .to_bytes()
                .strip_prefix(name)
                .and_then(|rest| rest.strip_prefix(b"="))
        })
    }

    /// Every entry as a name and a value; an entry without `=` has an empty value.
    pub fn entries(&self) -> impl Iterator<Item = (&'static [u8], &'static [u8])> {
        self.0.iter().map(|e| {
            let e = e.to_bytes();
            let name = Env::name(e);
            (name, e.get(name.len() + 1..).unwrap_or_default())
        })
    }

    /// The name of an entry: the bytes before its first `=`.
    pub fn name(entry: &[u8]) -> &[u8] {
        entry.split(|&c| c == b'=').next().unwrap_or(entry)
    }

    pub fn raw(&self) -> &[&'static CStr] {
        self.0
    }
}

/// Runs one call and returns its exit status.
pub fn main(args: &[&'static CStr], env: &[&'static CStr]) -> i32 {
    let env = Env(env);
    let words = args.get(1..).unwrap_or_default();
    let interactive = interactive(&env);
    if words.first().map(|w| w.to_bytes()) == Some(b"run") {
        if let Err(failure) = check_env(&env) {
            return failure.report(interactive, b"env");
        }
        let paths = Paths::new(&env);
        let Err(ending) = run::run(&env, &paths, interactive, &words[1..]);
        for line in &ending.before {
            line.report(interactive, &paths.prefix);
        }
        return ending.last.report(interactive, &paths.prefix);
    }
    let words: Vec<&[u8]> = words.iter().map(|w| w.to_bytes()).collect();
    match dispatch(&words, &env) {
        Ok(out) => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout
                .write_all(out.as_bytes())
                .and_then(|()| stdout.flush());
            0
        }
        Err(failure) => failure.report(interactive, &Paths::new(&env).prefix),
    }
}

fn dispatch(words: &[&[u8]], env: &Env) -> Result<String, Failure> {
    match words.first().copied() {
        Some(b"--version") if words.len() == 1 => Ok(format!("lendk {}\n", tables::VERSION)),
        Some(b"--version") => Err(Failure::new("usage", "--version takes no arguments")),
        Some(b"--help") if words.len() == 1 => Ok(tables::help()),
        Some(b"--help") => Err(Failure::new("usage", "--help takes no arguments")),
        first => {
            check_env(env)?;
            let Some(verb) = first else {
                return Err(Failure::new("usage", "no verb given"));
            };
            let mut text = b"unknown verb '".to_vec();
            text.extend_from_slice(verb);
            text.push(b'\'');
            Err(Failure::new("usage", text))
        }
    }
}

/// Whether the call may prompt: LENDK_PROMPT, then the terminal. An invalid LENDK_PROMPT counts
/// as non-interactive.
fn interactive(env: &Env) -> bool {
    match env.get("LENDK_PROMPT").unwrap_or(b"auto") {
        b"allow" => true,
        b"auto" => sys::is_terminal(0) || sys::is_terminal(2),
        _ => false,
    }
}

/// The checks every call but `--help` and `--version` makes of lendk's variables.
fn check_env(env: &Env) -> Result<(), Failure> {
    let quoted = |name: &str, value: &[u8], hint: &str| {
        let mut text = format!("{name} is '").into_bytes();
        text.extend_from_slice(value);
        text.extend_from_slice(format!("'; {hint}").as_bytes());
        Failure::new("usage", text)
    };
    if let Some(value) = env.get("LENDK_PROMPT")
        && !matches!(value, b"auto" | b"never" | b"allow")
    {
        return Err(quoted("LENDK_PROMPT", value, "use auto, never or allow"));
    }
    for name in ["LENDK_MAP", "LENDK_SHIMS"] {
        if let Some(value) = env.get(name)
            && !value.is_empty()
            && !value.starts_with(b"/")
        {
            return Err(quoted(name, value, "use an absolute path"));
        }
    }
    if let Some(value) = env.get("LENDK_TIMEOUT")
        && !valid_timeout(value)
    {
        return Err(quoted(
            "LENDK_TIMEOUT",
            value,
            "use whole seconds from 1 to 3600",
        ));
    }
    Ok(())
}

fn valid_timeout(value: &[u8]) -> bool {
    (1..=4).contains(&value.len())
        && value[0] != b'0'
        && value.iter().all(u8::is_ascii_digit)
        && std::str::from_utf8(value)
            .ok()
            .and_then(|s| s.parse::<u16>().ok())
            .is_some_and(|n| n <= 3600)
}
