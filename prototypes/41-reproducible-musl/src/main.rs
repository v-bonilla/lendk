// lendk-shaped: decrypt an age file with an identity file, hold the value
// in a locked, zeroized buffer, export it and exec the target.
use std::ffi::{CString, OsString};
use std::io::Read;
use std::os::unix::ffi::OsStringExt;
use zeroize::Zeroizing;

fn main() {
    unsafe {
        libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0);
    }
    let args: Vec<OsString> = std::env::args_os().collect();
    if args.len() < 5 {
        eprintln!("usage: lendk-proto IDENTITY FILE VAR CMD [ARG...]");
        std::process::exit(2);
    }
    let ident = std::fs::read_to_string(&args[1]).expect("identity");
    let ids = age::IdentityFile::from_buffer(ident.as_bytes())
        .expect("identity file")
        .into_identities()
        .expect("identities");
    let file = std::fs::File::open(&args[2]).expect("file");
    let dec = age::Decryptor::new(file).expect("age header");
    let mut r = dec
        .decrypt(ids.iter().map(|i| i.as_ref() as &dyn age::Identity))
        .expect("decrypt");
    let mut value = Zeroizing::new(Vec::with_capacity(4096));
    r.read_to_end(&mut value).expect("read");
    unsafe {
        libc::mlock(value.as_ptr().cast(), value.capacity());
    }
    let mut kv = Zeroizing::new(args[3].clone().into_vec());
    kv.push(b'=');
    kv.extend_from_slice(&value);
    kv.push(0);
    let env = [kv.as_ptr().cast::<libc::c_char>(), std::ptr::null()];
    let argv: Vec<CString> = args[4..]
        .iter()
        .map(|a| CString::new(a.clone().into_vec()).expect("arg"))
        .collect();
    let mut argp: Vec<*const libc::c_char> = argv.iter().map(|a| a.as_ptr()).collect();
    argp.push(std::ptr::null());
    unsafe {
        libc::execve(argp[0], argp.as_ptr(), env.as_ptr());
    }
    eprintln!("lendk-proto: exec failed");
    std::process::exit(127);
}
