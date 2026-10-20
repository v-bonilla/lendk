//! System calls: the one module allowed `unsafe`. Each block states why it holds.
#![allow(unsafe_code)]

use std::ffi::{CStr, c_char, c_int};

/// The process entry: lendk reads its arguments and environment from what exec handed it,
/// never through `std::env`. The unit tests keep the test harness's own entry.
#[cfg(not(test))]
#[unsafe(no_mangle)]
extern "C" fn main(argc: c_int, argv: *const *const c_char, envp: *const *const c_char) -> c_int {
    let args = c_strings(argv, usize::try_from(argc).unwrap_or(0));
    let env = c_strings(envp, usize::MAX);
    crate::cli::main(&args, &env)
}

/// Copies the strings of a NULL-terminated array, at most `max` of them.
fn c_strings(array: *const *const c_char, max: usize) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    if array.is_null() {
        return out;
    }
    for i in 0..max {
        // SAFETY: exec hands main argv and envp as NULL-terminated arrays, and argv holds argc
        // entries before its NULL; the loop stops at the first NULL, so i never passes the end.
        let entry = unsafe { *array.add(i) };
        if entry.is_null() {
            break;
        }
        // SAFETY: each entry exec hands over is a NUL-terminated string that lives as long as
        // the process.
        out.push(unsafe { CStr::from_ptr(entry) }.to_bytes().to_vec());
    }
    out
}

/// Whether descriptor `fd` is a terminal.
pub fn is_terminal(fd: c_int) -> bool {
    // SAFETY: isatty takes any descriptor number and only reports on it.
    unsafe { libc::isatty(fd) == 1 }
}
