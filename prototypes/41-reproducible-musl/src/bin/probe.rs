// Probe: does the allocator move the block when age shrinks a decrypted
// chunk (Vec::into_boxed_slice in SecretSlice::from), leaving an unzeroed
// copy behind? Each shrinking realloc is checked: if the block moved, the
// old block is read back through /proc/self/mem and scanned for the marker.
use std::alloc::{GlobalAlloc, Layout, System};
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering::Relaxed};

const MARK: &[u8; 8] = b"SENTINEL";

static ON: AtomicBool = AtomicBool::new(false);
static MEM: AtomicI32 = AtomicI32::new(-1);
static SHRINKS: AtomicUsize = AtomicUsize::new(0);
static MOVED: AtomicUsize = AtomicUsize::new(0);
static LEFT: AtomicUsize = AtomicUsize::new(0);
static LEFT_BYTES: AtomicUsize = AtomicUsize::new(0);
static FREED_WITH_MARK: AtomicUsize = AtomicUsize::new(0);
static mut SCRATCH: [u8; 1 << 17] = [0; 1 << 17];

fn count_marks(b: &[u8]) -> usize {
    b.windows(MARK.len()).filter(|w| w == MARK).count()
}

struct Probe;

unsafe impl GlobalAlloc for Probe {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        System.alloc(l)
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        if ON.load(Relaxed) && count_marks(std::slice::from_raw_parts(p, l.size())) > 0 {
            FREED_WITH_MARK.fetch_add(1, Relaxed);
        }
        System.dealloc(p, l)
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        let old = l.size();
        let q = System.realloc(p, l, new);
        if ON.load(Relaxed) && new < old {
            SHRINKS.fetch_add(1, Relaxed);
            if q != p {
                MOVED.fetch_add(1, Relaxed);
                let buf = &mut *std::ptr::addr_of_mut!(SCRATCH);
                let n = libc::pread(MEM.load(Relaxed), buf.as_mut_ptr().cast(), old.min(buf.len()), p as libc::off_t);
                if n > 0 {
                    let marks = count_marks(&buf[..n as usize]);
                    if marks > 0 {
                        LEFT.fetch_add(1, Relaxed);
                        LEFT_BYTES.fetch_add(marks * MARK.len(), Relaxed);
                    }
                }
            }
        }
        q
    }
}

#[global_allocator]
static A: Probe = Probe;

fn main() {
    let fd = unsafe { libc::open(c"/proc/self/mem".as_ptr(), libc::O_RDONLY) };
    assert!(fd >= 0, "open /proc/self/mem");
    MEM.store(fd, Relaxed);

    let id = age::x25519::Identity::generate();
    let rcpt = id.to_public();
    let mut sizes: Vec<usize> = (1..=512).collect();
    sizes.extend((9..=16).map(|s| 1usize << s));
    sizes.extend([65535, 65536, 65537, 100_000, 131_072, 200_000]);

    let mut out = std::io::stdout().lock();
    writeln!(out, "size shrinks moved moved_with_plaintext_left plaintext_bytes_left freed_with_plaintext").unwrap();
    let (mut tot_s, mut tot_m, mut tot_l) = (0, 0, 0);
    for &size in &sizes {
        let mut plain: Vec<u8> = MARK.iter().copied().cycle().take(size).collect();
        let mut ct = Vec::new();
        let enc = age::Encryptor::with_recipients(std::iter::once(&rcpt as &dyn age::Recipient)).unwrap();
        let mut w = enc.wrap_output(&mut ct).unwrap();
        w.write_all(&plain).unwrap();
        w.finish().unwrap();
        zeroize::Zeroize::zeroize(&mut plain);
        drop(plain);

        for c in [&SHRINKS, &MOVED, &LEFT, &LEFT_BYTES, &FREED_WITH_MARK] {
            c.store(0, Relaxed);
        }
        let dec = age::Decryptor::new(&ct[..]).unwrap();
        ON.store(true, Relaxed);
        let mut r = dec.decrypt(std::iter::once(&id as &dyn age::Identity)).unwrap();
        let mut sink = [0u8; 4096];
        let mut got = 0;
        loop {
            let n = r.read(&mut sink).unwrap();
            if n == 0 {
                break;
            }
            got += n;
        }
        drop(r);
        ON.store(false, Relaxed);
        assert_eq!(got, size);
        let (s, m, l) = (SHRINKS.load(Relaxed), MOVED.load(Relaxed), LEFT.load(Relaxed));
        tot_s += s;
        tot_m += m;
        tot_l += l;
        writeln!(out, "{size} {s} {m} {l} {} {}", LEFT_BYTES.load(Relaxed), FREED_WITH_MARK.load(Relaxed)).unwrap();
    }
    writeln!(out, "TOTAL sizes={} shrinks={tot_s} moved={tot_m} moved_with_plaintext_left={tot_l}", sizes.len()).unwrap();
}
