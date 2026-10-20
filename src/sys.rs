//! System calls: the one module allowed `unsafe`. Each block states why it holds.
#![allow(unsafe_code)]

use std::ffi::{CStr, CString, c_char, c_int};
use std::io;
use std::os::fd::{FromRawFd, OwnedFd};
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

/// Prepares a helper's child between fork and exec: it writes its PID to `report`, for the
/// watchdog, then leads a process group of its own, then dups `status` onto descriptor 9. A
/// signal that ends lendk's group before the child leaves it ends the child too.
pub fn helper_child(command: &mut std::process::Command, report: c_int, status: Option<c_int>) {
    use std::os::unix::process::CommandExt;
    // SAFETY: the closure runs between fork and exec and only calls getpid, write, setpgid and
    // dup2, which are async-signal-safe; report and status stay open in the parent until the
    // child has been spawned.
    unsafe {
        command.pre_exec(move || {
            let pid = libc::getpid().to_ne_bytes();
            libc::write(report, pid.as_ptr().cast(), pid.len());
            if libc::setpgid(0, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            if let Some(fd) = status
                && libc::dup2(fd, 9) == -1
            {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

/// A pipe whose ends close on exec, as (read, write).
pub fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0 as c_int; 2];
    // SAFETY: fds is a writable array of two descriptors, as pipe2 requires.
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: pipe2 succeeded, so both descriptors are open and owned by nothing else.
    Ok(unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) })
}

/// Forks. lendk runs one thread, so the child may run any code. Returns the child's PID in
/// the parent and 0 in the child.
pub fn fork() -> io::Result<i32> {
    // SAFETY: lendk is single-threaded, so the child holds no lock another thread took.
    let pid = unsafe { libc::fork() };
    if pid == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(pid)
}

/// Puts process `pid` in process group `pgid`; 0 means the caller or a group of its own.
pub fn setpgid(pid: i32, pgid: i32) {
    // SAFETY: setpgid takes plain integers.
    unsafe { libc::setpgid(pid, pgid) };
}

/// Sends `sig` to `pid` (a group when negative); whether a process received it.
pub fn kill(pid: i32, sig: c_int) -> bool {
    // SAFETY: kill takes plain integers.
    unsafe { libc::kill(pid, sig) == 0 }
}

/// Reaps `pid` when it has exited: its wait status, or None while it runs.
pub fn try_wait(pid: i32) -> Option<c_int> {
    let mut status = 0;
    // SAFETY: status is a writable int for the call.
    (unsafe { libc::waitpid(pid, &raw mut status, libc::WNOHANG) } == pid).then_some(status)
}

/// Waits for `pid` to exit and reaps it.
pub fn wait(pid: i32) {
    let mut status = 0;
    // SAFETY: status is a writable int for the call.
    while unsafe { libc::waitpid(pid, &raw mut status, 0) } == -1
        && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted
    {}
}

/// Whether `fd` is readable, or at its end, within `ms` milliseconds.
pub fn readable_within(fd: c_int, ms: c_int) -> io::Result<bool> {
    let mut pfd = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: pfd is one valid pollfd for the call.
    match unsafe { libc::poll(&raw mut pfd, 1, ms) } {
        -1 => {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                Ok(false)
            } else {
                Err(err)
            }
        }
        n => Ok(n > 0),
    }
}

/// Writes all of `buf` to `fd`.
pub fn write(fd: c_int, buf: &[u8]) -> bool {
    // SAFETY: buf is valid for reads of buf.len() bytes for the whole call.
    unsafe {
        libc::write(fd, buf.as_ptr().cast(), buf.len()) == isize::try_from(buf.len()).unwrap_or(-1)
    }
}

/// The watchdog's start in the forked child: a process group of its own, the job-control and
/// terminating signals but KILL ignored, and /dev/null as stdin, stdout and stderr, so it never
/// holds the caller's pipes.
pub fn detach() {
    // SAFETY: setpgid, signal with SIG_IGN, open and dup2 take plain values and a literal path.
    unsafe {
        libc::setpgid(0, 0);
        for sig in [
            libc::SIGTERM,
            libc::SIGINT,
            libc::SIGHUP,
            libc::SIGQUIT,
            libc::SIGTSTP,
            libc::SIGTTIN,
            libc::SIGTTOU,
            libc::SIGPIPE,
        ] {
            libc::signal(sig, libc::SIG_IGN);
        }
        let null = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR);
        if null >= 0 {
            for fd in 0..3 {
                libc::dup2(null, fd);
            }
            if null > 2 {
                libc::close(null);
            }
        }
    }
}

/// Ends the process at once, running no destructor.
pub fn exit_now(code: c_int) -> ! {
    // SAFETY: _exit takes a plain integer and never returns.
    unsafe { libc::_exit(code) }
}

/// The name of the terminal on `fd`, when it is one.
pub fn ttyname(fd: c_int) -> Option<Vec<u8>> {
    let mut buf = [0u8; 256];
    // SAFETY: buf is writable for its length, which ttyname_r is told.
    if unsafe { libc::ttyname_r(fd, buf.as_mut_ptr().cast(), buf.len()) } != 0 {
        return None;
    }
    let len = buf.iter().position(|&c| c == 0)?;
    Some(buf[..len].to_vec())
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
