//! Failure: a call ends with one class line, the FIX for its mode (ADR 0003) and the exit hint.

use crate::tables::CLASSES;
use std::io::Write;

/// A failure of class `id` (`CLASS` or `CLASS:FORM`, a row of the class table) with its TEXT.
#[derive(Debug)]
pub struct Failure {
    pub id: &'static str,
    pub text: Vec<u8>,
    subs: Vec<(&'static str, Vec<u8>)>,
}

impl Failure {
    pub fn new(id: &'static str, text: impl Into<Vec<u8>>) -> Self {
        Failure {
            id,
            text: text.into(),
            subs: Vec::new(),
        }
    }

    /// Puts `value` for each `token` (KEY, CMD, PATH...) in the FIX.
    pub fn with(mut self, token: &'static str, value: impl Into<Vec<u8>>) -> Self {
        self.subs.push((token, value.into()));
        self
    }

    /// The class line, `lendk: CLASS: TEXT. FIX`, and the exit hint, for the call's mode, with
    /// `env/` in the FIX read as the entry prefix `PREFIX/`.
    pub fn line(&self, interactive: bool, prefix: &[u8]) -> (Vec<u8>, i32) {
        let row = CLASSES
            .iter()
            .find(|c| c.id == self.id)
            .expect("every failure names a row of the class table");
        let fix = if interactive {
            row.interactive
        } else {
            row.non_interactive
        };
        let class = self.id.split(':').next().unwrap_or(self.id);
        let mut line = format!("lendk: {class}: ").into_bytes();
        line.extend_from_slice(&self.text);
        line.extend_from_slice(b". ");
        line.extend_from_slice(&self.fix(fix, prefix));
        line.push(b'\n');
        (line, i32::from(row.hint))
    }

    /// The FIX with the prefix and tokens in place. Markers stand in first, so no value is
    /// rewritten in turn.
    fn fix(&self, fix: &str, prefix: &[u8]) -> Vec<u8> {
        let marker = |i: u8| vec![1, i, 2];
        let mut out = replace(fix.as_bytes(), b"env/", &marker(0));
        for (i, (token, _)) in (1u8..).zip(&self.subs) {
            out = replace(&out, token.as_bytes(), &marker(i));
        }
        let mut with_prefix = prefix.to_vec();
        with_prefix.push(b'/');
        out = replace(&out, &marker(0), &with_prefix);
        for (i, (_, value)) in (1u8..).zip(&self.subs) {
            out = replace(&out, &marker(i), value);
        }
        out
    }

    /// Prints the class line to stderr and returns the exit hint.
    pub fn report(&self, interactive: bool, prefix: &[u8]) -> i32 {
        let (line, code) = self.line(interactive, prefix);
        let _ = std::io::stderr().write_all(&line);
        code
    }
}

/// Prints the contract's notice line, `lendk: notice: TEXT.`, to stderr.
pub fn notice(text: &[u8]) {
    let _ = std::io::stderr().write_all(&[&b"lendk: notice: "[..], text, b".\n"].concat());
}

fn replace(haystack: &[u8], from: &[u8], to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(haystack.len());
    let mut i = 0;
    while i < haystack.len() {
        if haystack[i..].starts_with(from) {
            out.extend_from_slice(to);
            i += from.len();
        } else {
            out.push(haystack[i]);
            i += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_form_prints_its_class_name_and_the_fix_for_the_mode() {
        let failure = Failure::new("map:group", "group @g is not defined");
        assert_eq!(
            failure.line(true, b"env"),
            (
                b"lendk: map: group @g is not defined. Define it first: lendk add @GROUP KEY...\n"
                    .to_vec(),
                125
            )
        );
        assert_eq!(
            failure.line(false, b"env").0,
            b"lendk: map: group @g is not defined. Stop and ask the user.\n".to_vec()
        );
    }

    #[test]
    fn every_class_gives_one_contract_line_and_its_exit_hint_in_both_modes() {
        let frozen = include_str!("../test/frozen/classes");
        for row in CLASSES {
            let class = row.id.split(':').next().unwrap();
            let hint = frozen
                .lines()
                .find_map(|l| l.strip_prefix(class)?.strip_prefix(" (")?.strip_suffix(')'))
                .unwrap_or_else(|| panic!("{class} is not in test/frozen/classes"));
            for interactive in [true, false] {
                let (line, code) = Failure::new(row.id, "planted text").line(interactive, b"env");
                let line = String::from_utf8(line).unwrap();
                assert!(line.starts_with(&format!("lendk: {class}: planted text. ")));
                assert_eq!(line.matches('\n').count(), 1);
                assert_eq!(code.to_string(), hint);
            }
        }
    }

    #[test]
    fn a_substituted_value_is_never_rewritten_by_the_prefix_or_another_token() {
        let failure = Failure::new("unsafe", "x").with("PATH", "/h/.env/KEY");
        assert_eq!(
            failure.line(true, b"api").0,
            b"lendk: unsafe: x. Fix it: chmod go-w /h/.env/KEY, or recreate it as your own\n"
                .to_vec()
        );
        let failure = Failure::new("missing-key", "x").with("KEY", "K");
        assert_eq!(
            failure.line(true, b"api").0,
            b"lendk: missing-key: x. Add it: pass insert api/K\n".to_vec()
        );
    }
}
