//! Plaintext: the one buffer that holds values, as the `NAME=value` entries of the target's
//! environment, each NUL-terminated and written once.

use crate::sys::Pages;
use std::ffi::c_char;
use std::fmt;
use std::io;

pub struct Plaintext {
    pages: Pages,
    len: usize,
}

impl Plaintext {
    /// A buffer of at least `capacity` bytes, sized before the first decrypt.
    pub fn with_capacity(capacity: usize) -> io::Result<Self> {
        Ok(Plaintext {
            pages: Pages::new(capacity)?,
            len: 0,
        })
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.pages.as_slice()[..self.len]
    }

    /// Room for at least `more` bytes after the end. A bigger buffer takes a copy, and the old
    /// one is zeroed as it drops; nothing reallocates in place.
    pub fn reserve(&mut self, more: usize) -> io::Result<()> {
        let need = self.len + more;
        if need <= self.pages.as_slice().len() {
            return Ok(());
        }
        let mut pages = Pages::new(need.max(self.pages.as_slice().len() * 2))?;
        pages.as_mut_slice()[..self.len].copy_from_slice(self.as_bytes());
        self.pages = pages;
        Ok(())
    }

    pub fn push(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.reserve(bytes.len())?;
        self.pages.as_mut_slice()[self.len..self.len + bytes.len()].copy_from_slice(bytes);
        self.len += bytes.len();
        Ok(())
    }

    /// The free space after the end, for read(2) to fill; `commit` then counts what it wrote.
    pub fn spare(&mut self) -> &mut [u8] {
        let len = self.len;
        &mut self.pages.as_mut_slice()[len..]
    }

    pub fn commit(&mut self, n: usize) {
        self.len += n;
    }

    /// Zeroes everything from `len` on and ends the buffer there.
    pub fn truncate(&mut self, len: usize) {
        if len < self.len {
            zeroize::Zeroize::zeroize(&mut self.pages.as_mut_slice()[len..self.len]);
            self.len = len;
        }
    }

    /// The address of the entry that starts at `offset`, for the exec environment.
    pub fn entry_ptr(&self, offset: usize) -> *const c_char {
        self.pages.ptr_at(offset)
    }
}

impl fmt::Debug for Plaintext {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Plaintext({} bytes)", self.len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn growing_keeps_the_bytes_and_debug_shows_none() {
        let mut p = Plaintext::with_capacity(8).unwrap();
        p.push(b"K=secret-value\0").unwrap();
        p.reserve(100_000).unwrap();
        assert_eq!(p.as_bytes(), b"K=secret-value\0");
        assert_eq!(format!("{p:?}"), "Plaintext(15 bytes)");
    }

    #[test]
    fn truncate_ends_the_buffer() {
        let mut p = Plaintext::with_capacity(8).unwrap();
        p.push(b"K=one\ntwo").unwrap();
        p.truncate(5);
        assert_eq!(p.as_bytes(), b"K=one");
    }
}
