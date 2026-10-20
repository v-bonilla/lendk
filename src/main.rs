//! lendk: give API keys stored in pass to the commands that need them.
#![cfg_attr(not(test), no_main)]
// The unit tests build without the C main, so what only it reaches looks unused there.
#![cfg_attr(test, allow(dead_code))]
#![deny(unsafe_code)]
#![deny(clippy::undocumented_unsafe_blocks)]

mod check;
mod cli;
mod edit;
mod exec;
mod failure;
mod helpers;
mod init;
mod map;
mod pass;
mod plaintext;
mod run;
mod shims;
mod sys;
mod tables;
mod unlock;
mod upgrade;
