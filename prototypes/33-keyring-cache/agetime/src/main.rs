//! PROTOTYPE for #33, throwaway. Writes and opens an age scrypt file holding a fresh X25519
//! identity, as #24's `lendk setup` writes and #23's unlock opens `$XDG_DATA_HOME/lendk/identity`.
//! The passphrase comes from `PROTO33_PASSPHRASE`, a prototype shortcut lendk never takes.
//!
//!   agetime write OUT LOG_N         encrypt a fresh identity to the passphrase at work factor 2^LOG_N
//!   agetime open IN MAX_LOG_N|default
//!                                   open it with the age crate, accepting work factors up to 2^MAX_LOG_N
//!                                   (default: the crate's own limit), and print the time it took

use age::secrecy::SecretString;
use std::io::{Read, Write};
use std::time::Instant;

fn passphrase() -> SecretString {
    SecretString::from(std::env::var("PROTO33_PASSPHRASE").expect("PROTO33_PASSPHRASE"))
}

fn header_log_n(path: &str) -> String {
    let data = std::fs::read(path).expect("read");
    let text = String::from_utf8_lossy(&data[..data.len().min(200)]).into_owned();
    text.lines()
        .find(|l| l.starts_with("-> scrypt "))
        .and_then(|l| l.split_whitespace().nth(3).map(str::to_string))
        .unwrap_or_else(|| "-".into())
}

fn write(out: &str, log_n: u8) {
    let identity = age::x25519::Identity::generate();
    let mut plain = format!("# public key: {}\n", identity.to_public());
    {
        use age::secrecy::ExposeSecret;
        plain.push_str(identity.to_string().expose_secret());
        plain.push('\n');
    }
    let mut r = age::scrypt::Recipient::new(passphrase());
    r.set_work_factor(log_n);
    let t = Instant::now();
    let enc = age::Encryptor::with_recipients(std::iter::once(&r as &dyn age::Recipient)).expect("recipients");
    let mut w = enc.wrap_output(std::fs::File::create(out).expect("create")).expect("wrap");
    w.write_all(plain.as_bytes()).expect("write");
    w.finish().expect("finish");
    println!("write=ok log_n={log_n} ms={}", t.elapsed().as_millis());
}

fn open(input: &str, max: Option<u8>) {
    let t = Instant::now();
    let mut id = age::scrypt::Identity::new(passphrase());
    let calibrate_ms = t.elapsed().as_millis();
    if let Some(m) = max {
        id.set_max_work_factor(m);
    }
    let f = std::fs::File::open(input).expect("open");
    let res = age::Decryptor::new(f).and_then(|d| d.decrypt(std::iter::once(&id as &dyn age::Identity)));
    let max_s = max.map(|m| m.to_string()).unwrap_or_else(|| "default".into());
    match res {
        Ok(mut r) => {
            let mut out = Vec::new();
            r.read_to_end(&mut out).expect("read");
            let ok = out.windows(15).any(|w| w == b"AGE-SECRET-KEY-");
            println!(
                "open=ok identity={} file_log_n={} max={max_s} ms={} calibrate_ms={calibrate_ms}",
                if ok { "yes" } else { "no" },
                header_log_n(input),
                t.elapsed().as_millis()
            );
        }
        Err(e) => println!(
            "open=err file_log_n={} max={max_s} ms={} error=\"{e}\"",
            header_log_n(input),
            t.elapsed().as_millis()
        ),
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("write") => write(&a[2], a[3].parse().expect("LOG_N")),
        Some("open") => open(&a[2], a.get(3).filter(|m| *m != "default").map(|m| m.parse().expect("MAX_LOG_N"))),
        _ => {
            eprintln!("usage: agetime write OUT LOG_N | agetime open IN MAX_LOG_N|default");
            std::process::exit(2)
        }
    }
}
