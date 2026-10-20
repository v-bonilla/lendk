//! System calls: the one module allowed `unsafe`. Each block states why it holds.
#![allow(unsafe_code)]

use std::ffi::{CStr, CString, c_char, c_int};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// The process entry: lendk reads its arguments and environment from what exec handed it,
/// never through `std::env`. The unit tests keep the test harness's own entry.
#[cfg(not(test))]
#[unsafe(no_mangle)]
extern "C" fn main(argc: c_int, argv: *const *const c_char, envp: *const *const c_char) -> c_int {
    // SAFETY: prctl with PR_SET_DUMPABLE takes a plain integer and touches no memory of ours.
    unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) };
    for fd in 0..3 {
        // SAFETY: fcntl F_GETFD only reports on the descriptor number.
        if unsafe { libc::fcntl(fd, libc::F_GETFD) } == -1 {
            // SAFETY: the path is a NUL-terminated literal; open takes the lowest free
            // descriptor, which is fd, since the lower ones are open by now.
            unsafe { libc::open(c"/dev/null".as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
        }
    }
    let args = c_strings(argv, usize::try_from(argc).unwrap_or(0));
    let env = c_strings(envp, usize::MAX);
    crate::cli::main(&args, &env)
}

/// The strings of a NULL-terminated array, at most `max` of them, where exec put them.
fn c_strings(array: *const *const c_char, max: usize) -> Vec<&'static CStr> {
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
        // the process and that lendk never writes.
        out.push(unsafe { CStr::from_ptr(entry) });
    }
    out
}

/// Whether descriptor `fd` is a terminal.
pub fn is_terminal(fd: c_int) -> bool {
    // SAFETY: isatty takes any descriptor number and only reports on it.
    unsafe { libc::isatty(fd) == 1 }
}

/// The effective user ID.
pub fn euid() -> u32 {
    // SAFETY: geteuid takes nothing and cannot fail.
    unsafe { libc::geteuid() }
}

/// Whether the effective user may execute `path`, as bash's `-x` tests it.
pub fn executable(path: &[u8]) -> bool {
    let Ok(path) = CString::new(path) else {
        return false;
    };
    // SAFETY: path is NUL-terminated and outlives the call.
    unsafe { libc::faccessat(libc::AT_FDCWD, path.as_ptr(), libc::X_OK, libc::AT_EACCESS) == 0 }
}

/// Creates a private directory from `template`, which ends in `XXXXXX`, and returns its path.
pub fn mkdtemp(template: &[u8]) -> io::Result<Vec<u8>> {
    let mut buf = CString::new(template)?.into_bytes_with_nul();
    // SAFETY: buf is a writable NUL-terminated template that mkdtemp fills in place.
    let made = unsafe { libc::mkdtemp(buf.as_mut_ptr().cast()) };
    if made.is_null() {
        return Err(io::Error::last_os_error());
    }
    buf.pop();
    Ok(buf)
}

/// Reads from `fd` into `buf` with read(2), retrying on EINTR.
pub fn read(fd: c_int, buf: &mut [u8]) -> io::Result<usize> {
    loop {
        // SAFETY: buf is valid for writes of buf.len() bytes for the whole call.
        let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
        if let Ok(n) = usize::try_from(n) {
            return Ok(n);
        }
        let err = io::Error::last_os_error();
        if err.kind() != io::ErrorKind::Interrupted {
            return Err(err);
        }
    }
}

/// Makes the `std::process::Command` dup `fd` onto descriptor 9 in the child, for gpg's status.
pub fn status_fd_9(command: &mut std::process::Command, fd: c_int) {
    use std::os::unix::process::CommandExt;
    // SAFETY: the closure runs between fork and exec and only calls dup2, which is
    // async-signal-safe; fd stays open in the parent until the child has been spawned.
    unsafe {
        command.pre_exec(move || {
            if libc::dup2(fd, 9) == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

/// Replaces the process with `path`. It returns only on failure, with the error.
pub fn execve(path: &[u8], argv: &[&CStr], envp: &[*const c_char]) -> io::Error {
    let Ok(path) = CString::new(path) else {
        return io::Error::from(io::ErrorKind::InvalidInput);
    };
    let mut argv: Vec<*const c_char> = argv.iter().map(|a| a.as_ptr()).collect();
    argv.push(std::ptr::null());
    let mut envp = envp.to_vec();
    envp.push(std::ptr::null());
    // SAFETY: path and every argv and envp entry are NUL-terminated strings that live until
    // execve returns, and both arrays end with NULL.
    unsafe { libc::execve(path.as_ptr(), argv.as_ptr(), envp.as_ptr()) };
    io::Error::last_os_error()
}

/// Anonymous private memory of whole pages, kept out of swap with mlock where the limit
/// allows, left out of core dumps, and zeroed before it is unmapped.
pub struct Pages {
    ptr: *mut u8,
    len: usize,
}

impl Pages {
    /// Maps at least `len` bytes, rounded up to whole pages.
    pub fn new(len: usize) -> io::Result<Self> {
        // SAFETY: sysconf only reports a value.
        let page = usize::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) }).unwrap_or(4096);
        let len = len.max(1).div_ceil(page) * page;
        // SAFETY: an anonymous private mapping with no address hint touches no existing memory.
        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
                -1,
                0,
            )
        };
        if ptr == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: ptr and len describe the mapping made above. A failed mlock, as under
        // ulimit -l 0, leaves the memory usable, and a failed madvise only keeps it in dumps.
        unsafe {
            libc::mlock(ptr, len);
            #[cfg(target_os = "linux")]
            libc::madvise(ptr, len, libc::MADV_DONTDUMP);
        }
        Ok(Pages {
            ptr: ptr.cast(),
            len,
        })
    }

    pub fn as_slice(&self) -> &[u8] {
        // SAFETY: ptr points to len bytes mapped readable and writable until drop.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }

    pub fn as_mut_slice(&mut self) -> &mut [u8] {
        // SAFETY: as in as_slice, and &mut self makes this the only reference.
        unsafe { std::slice::from_raw_parts_mut(self.ptr, self.len) }
    }

    /// The address of the byte at `offset`, for an exec environment entry.
    pub fn ptr_at(&self, offset: usize) -> *const c_char {
        self.as_slice()[offset..].as_ptr().cast()
    }
}

impl Drop for Pages {
    fn drop(&mut self) {
        zeroize::Zeroize::zeroize(self.as_mut_slice());
        // SAFETY: ptr and len describe the mapping this value owns, which nothing uses after drop.
        unsafe {
            libc::munlock(self.ptr.cast(), self.len);
            libc::munmap(self.ptr.cast(), self.len);
        }
    }
}

/// Whether two paths name the same file, as bash's `-ef` tests it.
pub fn same_file(a: &[u8], b: &[u8]) -> bool {
    use std::os::unix::fs::MetadataExt;
    let meta = |p: &[u8]| std::fs::metadata(Path::new(std::ffi::OsStr::from_bytes(p)));
    match (meta(a), meta(b)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    }
}

/// The path lendk was started by, as exec was handed it: symlinks unresolved, relative when
/// the caller gave a relative path. None when the kernel does not say.
pub fn exec_path() -> Option<Vec<u8>> {
    // SAFETY: getauxval only reads the auxiliary vector the kernel handed the process.
    let at = unsafe { libc::getauxval(libc::AT_EXECFN) };
    if at == 0 {
        return None;
    }
    // SAFETY: AT_EXECFN points to the NUL-terminated file name exec was given, which lives on
    // the process's initial stack for its whole life and is never written.
    let name = unsafe { CStr::from_ptr(at as *const c_char) };
    Some(name.to_bytes().to_vec())
}

/// Whether process `pid` exists and may be signaled, as bash's `kill -0` finds it.
pub fn alive(pid: &[u8]) -> bool {
    let Some(pid) = std::str::from_utf8(pid)
        .ok()
        .and_then(|p| p.parse::<i32>().ok())
    else {
        return false;
    };
    // SAFETY: kill with signal 0 sends nothing; it only checks the process.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Blocks HUP, INT and TERM, or unblocks them, so a write under the lock finishes and releases
/// it before such a signal ends the call.
pub fn hold_signals(block: bool) {
    // SAFETY: set is a local signal set that sigemptyset initializes before use, and
    // sigprocmask only reads it.
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        for sig in [libc::SIGHUP, libc::SIGINT, libc::SIGTERM] {
            libc::sigaddset(&mut set, sig);
        }
        let how = if block {
            libc::SIG_BLOCK
        } else {
            libc::SIG_UNBLOCK
        };
        libc::sigprocmask(how, &set, std::ptr::null_mut());
    }
}
