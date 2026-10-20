//! Failure: a call ends with one class line, the FIX for its mode (ADR 0003) and the exit hint.

use crate::tables::CLASSES;
use std::io::Write;

/// A failure of class `id` (`CLASS` or `CLASS:FORM`, a row of the class table) with its TEXT.
pub struct Failure {
    pub id: &'static str,
    pub text: Vec<u8>,
}

impl Failure {
    pub fn new(id: &'static str, text: impl Into<Vec<u8>>) -> Self {
        Failure {
            id,
            text: text.into(),
        }
    }

    /// The class line, `lendk: CLASS: TEXT. FIX`, and the exit hint, for the call's mode.
    pub fn line(&self, interactive: bool) -> (Vec<u8>, i32) {
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
        line.extend_from_slice(format!(". {fix}\n").as_bytes());
        (line, i32::from(row.hint))
    }

    /// Prints the class line to stderr and returns the exit hint.
    pub fn report(&self, interactive: bool) -> i32 {
        let (line, code) = self.line(interactive);
        let _ = std::io::stderr().write_all(&line);
        code
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_form_prints_its_class_name_and_the_fix_for_the_mode() {
        let failure = Failure::new("map:group", "group @g is not defined");
        assert_eq!(
            failure.line(true),
            (
                b"lendk: map: group @g is not defined. Define it first: lendk add @GROUP KEY...\n"
                    .to_vec(),
                125
            )
        );
        assert_eq!(
            failure.line(false).0,
            b"lendk: map: group @g is not defined. Stop and ask the user.\n".to_vec()
        );
    }
}
