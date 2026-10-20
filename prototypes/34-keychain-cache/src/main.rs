//! PROTOTYPE for lendk #34, throwaway, never merged: checks whether a login keychain item can
//! hold lendk 2.0's unlocked identity, as #23 relies on. `probe.sh` drives it; see README.md.
//!
//! Each command prints one `probe:` line per result on stdout. The item holds a fixed dummy,
//! never a secret, and the probe refuses to run unless `$HOME/KEYCHAIN-PROBE-THROWAWAY` exists.
#![allow(non_upper_case_globals, non_snake_case)]

use core_foundation_sys::array::{
    kCFTypeArrayCallBacks, CFArrayCreate, CFArrayGetCount, CFArrayGetValueAtIndex, CFArrayRef,
};
use core_foundation_sys::base::{kCFAllocatorDefault, CFGetTypeID, CFIndex, CFTypeRef, OSStatus};
use core_foundation_sys::data::{
    CFDataCreate, CFDataGetBytePtr, CFDataGetLength, CFDataGetTypeID, CFDataRef,
};
use core_foundation_sys::dictionary::{
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks, CFDictionaryCreateMutable,
    CFDictionarySetValue, CFMutableDictionaryRef,
};
use core_foundation_sys::number::kCFBooleanTrue;
use core_foundation_sys::string::{
    kCFStringEncodingUTF8, CFStringCreateWithBytes, CFStringGetCString, CFStringGetLength,
    CFStringGetMaximumSizeForEncoding, CFStringRef,
};
use security_framework_sys::base::{SecAccessRef, SecCopyErrorMessageString, SecKeychainItemRef, SecKeychainRef};
use security_framework_sys::code_signing::SecRequirementRef;
use security_framework_sys::item::{
    kSecAttrAccount, kSecAttrLabel, kSecAttrService, kSecClass, kSecClassGenericPassword,
    kSecMatchLimit, kSecMatchLimitAll, kSecMatchSearchList, kSecReturnData, kSecReturnRef,
    kSecUseAuthenticationContext, kSecUseAuthenticationUI, kSecUseKeychain, kSecValueData,
};
use security_framework_sys::keychain::{
    SecKeychainCopyDefault, SecKeychainCreate, SecKeychainFindGenericPassword,
    SecKeychainGetUserInteractionAllowed, SecKeychainOpen, SecKeychainSetUserInteractionAllowed,
    SecKeychainSettings, SecKeychainUnlock, SEC_KEYCHAIN_SETTINGS_VERS1,
};
use security_framework_sys::keychain_item::{
    SecItemAdd, SecItemCopyMatching, SecItemDelete, SecKeychainItemFreeContent,
};
use std::ffi::{c_char, c_void, CString};
use std::io::Read;
use std::ptr::{null, null_mut};
use std::time::{Duration, Instant};

const SERVICE: &str = "lendk-probe";
// #23 names the item's account after the identity's recipient; this one only looks like one.
const ACCOUNT: &str = "age1prototype34keychaincacheprobe";
const DUMMY: &str = "PROBE-DUMMY-IDENTITY-NOT-A-SECRET";
const TEST_KEYCHAIN_PASSWORD: &str = "lendk-probe-test";
const GUARD: &str = "KEYCHAIN-PROBE-THROWAWAY";
// A different value per build changes the binary, and with it the ad-hoc signature's cdhash.
const RELEASE: &str = match option_env!("PROBE_RELEASE") {
    Some(r) => r,
    None => "dev",
};

/// What security-framework-sys 2.17.0 and core-foundation-sys 0.8.7 do not bind, which lendk
/// would declare itself (#27). Signatures follow the macOS SDK headers.
mod extra {
    use super::*;

    pub type SecACLRef = *const c_void;
    pub type SecTrustedApplicationRef = *const c_void;

    pub const kSecUnlockStateStatus: u32 = 1;
    pub const kSecReadPermStatus: u32 = 2;
    pub const kSecWritePermStatus: u32 = 4;
    pub const kSecKeychainPromptRequirePassphase: u16 = 0x0001;
    pub const callerSecuritySession: u32 = u32::MAX;
    pub const sessionIsRoot: u32 = 0x0001;
    pub const sessionHasGraphicAccess: u32 = 0x0010;
    pub const sessionHasTTY: u32 = 0x0020;
    pub const sessionIsRemote: u32 = 0x1000;

    #[link(name = "Security", kind = "framework")]
    extern "C" {
        pub static kSecUseAuthenticationUIFail: CFStringRef;
        pub static kSecAttrAccess: CFStringRef;
        pub static kSecACLAuthorizationDecrypt: CFStringRef;
        pub fn SecKeychainGetStatus(keychain: SecKeychainRef, status: *mut u32) -> OSStatus;
        pub fn SecKeychainLock(keychain: SecKeychainRef) -> OSStatus;
        pub fn SecKeychainDelete(keychain: SecKeychainRef) -> OSStatus;
        pub fn SecKeychainCopySettings(keychain: SecKeychainRef, settings: *mut SecKeychainSettings) -> OSStatus;
        pub fn SecKeychainGetPath(keychain: SecKeychainRef, length: *mut u32, path: *mut c_char) -> OSStatus;
        pub fn SecKeychainItemCopyAccess(item: SecKeychainItemRef, access: *mut SecAccessRef) -> OSStatus;
        pub fn SecAccessCreate(descriptor: CFStringRef, trusted: CFArrayRef, access: *mut SecAccessRef) -> OSStatus;
        pub fn SecAccessCopyACLList(access: SecAccessRef, list: *mut CFArrayRef) -> OSStatus;
        pub fn SecAccessCopyMatchingACLList(access: SecAccessRef, tag: CFTypeRef) -> CFArrayRef;
        pub fn SecACLCopyAuthorizations(acl: SecACLRef) -> CFArrayRef;
        pub fn SecACLCopyContents(
            acl: SecACLRef,
            apps: *mut CFArrayRef,
            description: *mut CFStringRef,
            prompt: *mut u16,
        ) -> OSStatus;
        pub fn SecACLSetContents(acl: SecACLRef, apps: CFArrayRef, description: CFStringRef, prompt: u16) -> OSStatus;
        pub fn SecTrustedApplicationCopyData(app: SecTrustedApplicationRef, data: *mut CFDataRef) -> OSStatus;
        pub fn SecTrustedApplicationCopyRequirement(
            app: SecTrustedApplicationRef,
            requirement: *mut SecRequirementRef,
        ) -> OSStatus;
        pub fn SecRequirementCopyString(requirement: SecRequirementRef, flags: u32, text: *mut CFStringRef) -> OSStatus;
        pub fn SessionGetInfo(session: u32, id: *mut u32, attributes: *mut u32) -> OSStatus;
    }

    #[link(name = "objc")]
    extern "C" {
        pub fn objc_getClass(name: *const c_char) -> *mut c_void;
        pub fn sel_registerName(name: *const c_char) -> *mut c_void;
        pub fn objc_msgSend();
    }

    #[link(name = "LocalAuthentication", kind = "framework")]
    extern "C" {
        pub static LAErrorDomain: CFStringRef;
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Api {
    SecItem,
    SecKeychain,
}

#[derive(Clone, Copy, PartialEq)]
enum Suppress {
    None,
    Flag,
    UiFail,
    LaContext,
}

struct Opts {
    cmd: String,
    keychain: String,
    api: Api,
    suppress: Suppress,
    any_app: bool,
    watchdog: u64,
    no_password: bool,
    login_password: bool,
    path: Option<String>,
}

fn parse() -> Result<Opts, String> {
    let mut args = std::env::args().skip(1);
    let cmd = args.next().ok_or("usage: keychain-probe COMMAND [OPTION...]; see README.md")?;
    let mut o = Opts {
        cmd,
        keychain: "login".into(),
        api: Api::SecItem,
        suppress: Suppress::Flag,
        any_app: false,
        watchdog: 0,
        no_password: false,
        login_password: false,
        path: None,
    };
    while let Some(a) = args.next() {
        match a.as_str() {
            "--keychain" => o.keychain = args.next().ok_or("--keychain takes login or a path")?,
            "--api" => {
                o.api = match args.next().as_deref() {
                    Some("secitem") => Api::SecItem,
                    Some("seckeychain") => Api::SecKeychain,
                    _ => return Err("--api takes secitem or seckeychain".into()),
                }
            }
            "--suppress" => {
                o.suppress = match args.next().as_deref() {
                    Some("none") => Suppress::None,
                    Some("flag") => Suppress::Flag,
                    Some("uifail") => Suppress::UiFail,
                    Some("lacontext") => Suppress::LaContext,
                    _ => return Err("--suppress takes none, flag, uifail or lacontext".into()),
                }
            }
            "--acl" => {
                o.any_app = match args.next().as_deref() {
                    Some("default") => false,
                    Some("any") => true,
                    _ => return Err("--acl takes default or any".into()),
                }
            }
            "--watchdog" => o.watchdog = args.next().and_then(|s| s.parse().ok()).ok_or("--watchdog takes seconds")?,
            "--no-password" => o.no_password = true,
            "--login-password" => o.login_password = true,
            _ if !a.starts_with("--") && o.path.is_none() => o.path = Some(a),
            _ => return Err(format!("unknown argument: {a}")),
        }
    }
    if o.cmd.starts_with("tempkc-") {
        o.keychain = o.path.clone().ok_or("tempkc-create and tempkc-delete take a path")?;
    }
    Ok(o)
}

fn home() -> String {
    std::env::var("HOME").unwrap_or_default()
}

// Issue text allows no home path, so every path prints with $HOME as ~.
fn tilde(s: &str) -> String {
    let h = home();
    if h.is_empty() {
        s.into()
    } else {
        s.replace(&h, "~")
    }
}

fn emit(o: &Opts, fields: Vec<(&str, String)>) {
    let api = match o.api {
        Api::SecItem => "secitem",
        Api::SecKeychain => "seckeychain",
    };
    let suppress = match o.suppress {
        Suppress::None => "none",
        Suppress::Flag => "flag",
        Suppress::UiFail => "uifail",
        Suppress::LaContext => "lacontext",
    };
    let mut line = format!(
        "probe: release={RELEASE} cmd={} keychain={} api={api} suppress={suppress}",
        o.cmd,
        tilde(&o.keychain)
    );
    for (k, v) in fields {
        let v = tilde(&v).replace('"', "'");
        if v.is_empty() || v.contains(' ') {
            line += &format!(" {k}=\"{v}\"");
        } else {
            line += &format!(" {k}={v}");
        }
    }
    println!("{line}");
}

fn status_name(code: OSStatus) -> &'static str {
    match code {
        0 => "errSecSuccess",
        -50 => "errSecParam",
        -61 => "errSecWrPerm",
        -128 => "errSecUserCanceled",
        -25243 => "errSecNoAccessForItem",
        -25291 => "errSecNotAvailable",
        -25293 => "errSecAuthFailed",
        -25294 => "errSecNoSuchKeychain",
        -25299 => "errSecDuplicateItem",
        -25300 => "errSecItemNotFound",
        -25307 => "errSecNoDefaultKeychain",
        -25308 => "errSecInteractionNotAllowed",
        -25315 => "errSecInteractionRequired",
        -34018 => "errSecMissingEntitlement",
        _ => "other",
    }
}

unsafe fn status_fields(code: OSStatus) -> Vec<(&'static str, String)> {
    vec![
        ("result", "returned".into()),
        ("status", code.to_string()),
        ("name", status_name(code).into()),
        ("message", string_of(SecCopyErrorMessageString(code, null_mut()))),
    ]
}

unsafe fn cfstr(s: &str) -> CFStringRef {
    CFStringCreateWithBytes(kCFAllocatorDefault, s.as_ptr(), s.len() as CFIndex, kCFStringEncodingUTF8, 0)
}

unsafe fn string_of(s: CFStringRef) -> String {
    if s.is_null() {
        return "-".into();
    }
    let max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
    let mut buf = vec![0u8; max as usize];
    if CFStringGetCString(s, buf.as_mut_ptr().cast(), max, kCFStringEncodingUTF8) == 0 {
        return "?".into();
    }
    let n = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..n]).into_owned()
}

unsafe fn set(q: CFMutableDictionaryRef, key: CFStringRef, value: *const c_void) {
    CFDictionarySetValue(q, key.cast(), value);
}

// The process exits from this thread when a call has not returned in time: a dialog is the
// likely reason, and probe.sh then asks the human what is on screen.
fn watchdog(o: &Opts) {
    if o.watchdog == 0 {
        return;
    }
    let secs = o.watchdog;
    let o = Opts {
        cmd: o.cmd.clone(),
        keychain: o.keychain.clone(),
        path: None,
        ..*o
    };
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(secs));
        emit(&o, vec![("result", "blocked".into()), ("after_s", secs.to_string())]);
        std::process::exit(3);
    });
}

fn keychain_path(spec: &str) -> String {
    if spec == "login" {
        format!("{}/Library/Keychains/login.keychain-db", home())
    } else {
        spec.into()
    }
}

// A test keychain left locked is unlocked with its known password when `unlock_test` is set,
// as the LENDK_TEST_CACHE hook would; the login keychain never is.
unsafe fn open_keychain(o: &Opts, unlock_test: bool) -> Option<SecKeychainRef> {
    let path = CString::new(keychain_path(&o.keychain)).ok()?;
    let mut kc: SecKeychainRef = null_mut();
    let st = SecKeychainOpen(path.as_ptr(), &mut kc);
    if st != 0 {
        let mut f = vec![("step", "SecKeychainOpen".into())];
        f.extend(status_fields(st));
        emit(o, f);
        return None;
    }
    if unlock_test && o.keychain != "login" {
        let mut s = 0u32;
        if extra::SecKeychainGetStatus(kc, &mut s) == 0 && s & extra::kSecUnlockStateStatus == 0 {
            let st = SecKeychainUnlock(kc, TEST_KEYCHAIN_PASSWORD.len() as u32, TEST_KEYCHAIN_PASSWORD.as_ptr().cast(), 1);
            let mut f = vec![("step", "unlock-test-keychain".into())];
            f.extend(status_fields(st));
            emit(o, f);
        }
    }
    Some(kc)
}

unsafe fn la_context() -> *const c_void {
    // Reading a LocalAuthentication symbol keeps the framework linked, so the class is registered.
    let _ = std::ptr::read_volatile(std::ptr::addr_of!(extra::LAErrorDomain));
    let class = extra::objc_getClass(c"LAContext".as_ptr());
    if class.is_null() {
        return null();
    }
    let send: unsafe extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
        std::mem::transmute(extra::objc_msgSend as unsafe extern "C" fn());
    let context = send(class, extra::sel_registerName(c"new".as_ptr()));
    let send_bool: unsafe extern "C" fn(*mut c_void, *mut c_void, i8) =
        std::mem::transmute(extra::objc_msgSend as unsafe extern "C" fn());
    send_bool(context, extra::sel_registerName(c"setInteractionNotAllowed:".as_ptr()), 1);
    context
}

// Writes target the keychain with kSecUseKeychain and reads search it alone, so a test keychain
// and the login keychain never see each other's item.
unsafe fn item_query(o: &Opts, kc: SecKeychainRef, adding: bool) -> Option<CFMutableDictionaryRef> {
    let q = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    set(q, kSecClass, kSecClassGenericPassword.cast());
    set(q, kSecAttrService, cfstr(SERVICE).cast());
    set(q, kSecAttrAccount, cfstr(ACCOUNT).cast());
    if adding {
        set(q, kSecUseKeychain, kc.cast_const().cast());
    } else {
        let list = [kc.cast_const().cast::<c_void>()];
        set(q, kSecMatchSearchList, CFArrayCreate(kCFAllocatorDefault, list.as_ptr(), 1, &kCFTypeArrayCallBacks).cast());
    }
    match o.suppress {
        Suppress::UiFail => set(q, kSecUseAuthenticationUI, extra::kSecUseAuthenticationUIFail.cast()),
        Suppress::LaContext => {
            let context = la_context();
            if context.is_null() {
                emit(o, vec![("step", "LAContext".into()), ("result", "no-class".into())]);
                return None;
            }
            set(q, kSecUseAuthenticationContext, context);
        }
        Suppress::None | Suppress::Flag => {}
    }
    Some(q)
}

fn describe(data: Option<Vec<u8>>, f: &mut Vec<(&str, String)>) {
    match data {
        None => f.push(("item", "none".into())),
        Some(d) => {
            let text = String::from_utf8_lossy(&d).into_owned();
            match text.strip_prefix(DUMMY).and_then(|r| r.strip_prefix(" written-by=")) {
                Some(writer) => {
                    f.push(("item", "dummy".into()));
                    f.push(("written_by", writer.into()));
                }
                None => {
                    f.push(("item", "unexpected".into()));
                    f.push(("bytes", d.len().to_string()));
                }
            }
        }
    }
}

unsafe fn cmd_read(o: &Opts) -> i32 {
    watchdog(o);
    let Some(kc) = open_keychain(o, true) else { return 1 };
    let started = Instant::now();
    let (st, data) = match o.api {
        Api::SecItem => {
            let Some(q) = item_query(o, kc, false) else { return 1 };
            set(q, kSecReturnData, kCFBooleanTrue.cast());
            let mut out: CFTypeRef = null();
            let st = SecItemCopyMatching(q.cast_const(), &mut out);
            let data = (st == 0 && !out.is_null() && CFGetTypeID(out) == CFDataGetTypeID()).then(|| {
                let d: CFDataRef = out.cast();
                std::slice::from_raw_parts(CFDataGetBytePtr(d), CFDataGetLength(d) as usize).to_vec()
            });
            (st, data)
        }
        Api::SecKeychain => {
            let mut len = 0u32;
            let mut ptr: *mut c_void = null_mut();
            let st = SecKeychainFindGenericPassword(
                kc.cast_const().cast(),
                SERVICE.len() as u32,
                SERVICE.as_ptr().cast(),
                ACCOUNT.len() as u32,
                ACCOUNT.as_ptr().cast(),
                &mut len,
                &mut ptr,
                null_mut(),
            );
            let data = (st == 0 && !ptr.is_null()).then(|| {
                let v = std::slice::from_raw_parts(ptr.cast::<u8>(), len as usize).to_vec();
                // This API hands lendk a buffer it frees itself, so lendk could zero it first.
                std::ptr::write_bytes(ptr.cast::<u8>(), 0, len as usize);
                SecKeychainItemFreeContent(null_mut(), ptr);
                v
            });
            (st, data)
        }
    };
    let mut f = status_fields(st);
    describe(data, &mut f);
    f.push(("elapsed_ms", started.elapsed().as_millis().to_string()));
    emit(o, f);
    i32::from(st != 0)
}

// A NULL list makes SecAccessCreate trust the creating application alone (SecAccess.h), and
// makes SecACLSetContents allow any application (SecACL.cpp), so the decrypt entries open to
// any application, as `security add-generic-password -A` does; `acl` shows what was stored.
unsafe fn any_app_access(o: &Opts) -> Option<SecAccessRef> {
    let mut access: SecAccessRef = null_mut();
    let st = extra::SecAccessCreate(cfstr("lendk-probe"), null(), &mut access);
    if st != 0 {
        let mut f = vec![("step", "SecAccessCreate".into())];
        f.extend(status_fields(st));
        emit(o, f);
        return None;
    }
    let list = extra::SecAccessCopyMatchingACLList(access, extra::kSecACLAuthorizationDecrypt.cast());
    let n = if list.is_null() { 0 } else { CFArrayGetCount(list) };
    let mut opened = 0;
    for i in 0..n {
        let acl = CFArrayGetValueAtIndex(list, i);
        let mut apps: CFArrayRef = null();
        let mut desc: CFStringRef = null();
        let mut prompt = 0u16;
        if extra::SecACLCopyContents(acl, &mut apps, &mut desc, &mut prompt) == 0
            && extra::SecACLSetContents(acl, null(), desc, prompt & !extra::kSecKeychainPromptRequirePassphase) == 0
        {
            opened += 1;
        }
    }
    emit(
        o,
        vec![
            ("step", "SecAccessCreate".into()),
            ("decrypt_entries", n.to_string()),
            ("opened_to_any_app", opened.to_string()),
        ],
    );
    Some(access)
}

unsafe fn cmd_write(o: &Opts) -> i32 {
    watchdog(o);
    let Some(kc) = open_keychain(o, true) else { return 1 };
    let Some(q) = item_query(o, kc, true) else { return 1 };
    let content = format!("{DUMMY} written-by={RELEASE}");
    set(q, kSecValueData, CFDataCreate(kCFAllocatorDefault, content.as_ptr(), content.len() as CFIndex).cast());
    set(q, kSecAttrLabel, cfstr("lendk-probe, the #34 prototype").cast());
    if o.any_app {
        let Some(access) = any_app_access(o) else { return 1 };
        set(q, extra::kSecAttrAccess, access.cast_const().cast());
    }
    let started = Instant::now();
    let st = SecItemAdd(q.cast_const(), null_mut());
    let mut f = status_fields(st);
    f.push(("acl", if o.any_app { "any" } else { "default" }.into()));
    f.push(("elapsed_ms", started.elapsed().as_millis().to_string()));
    emit(o, f);
    i32::from(st != 0)
}

unsafe fn cmd_delete(o: &Opts) -> i32 {
    watchdog(o);
    let Some(kc) = open_keychain(o, true) else { return 1 };
    let Some(q) = item_query(o, kc, false) else { return 1 };
    set(q, kSecMatchLimit, kSecMatchLimitAll.cast());
    let started = Instant::now();
    let st = SecItemDelete(q.cast_const());
    let mut f = status_fields(st);
    f.push(("elapsed_ms", started.elapsed().as_millis().to_string()));
    emit(o, f);
    i32::from(st != 0)
}

unsafe fn strings_of(list: CFArrayRef) -> Vec<String> {
    if list.is_null() {
        return Vec::new();
    }
    (0..CFArrayGetCount(list)).map(|i| string_of(CFArrayGetValueAtIndex(list, i).cast())).collect()
}

unsafe fn apps_text(apps: CFArrayRef) -> String {
    if apps.is_null() {
        return "any".into();
    }
    let n = CFArrayGetCount(apps);
    if n == 0 {
        return "none".into();
    }
    let mut out = Vec::new();
    for i in 0..n {
        let app = CFArrayGetValueAtIndex(apps, i);
        let mut req: SecRequirementRef = null_mut();
        let mut text: CFStringRef = null();
        if extra::SecTrustedApplicationCopyRequirement(app, &mut req) == 0
            && !req.is_null()
            && extra::SecRequirementCopyString(req, 0, &mut text) == 0
        {
            out.push(format!("requirement:{}", string_of(text)));
            continue;
        }
        let mut data: CFDataRef = null();
        if extra::SecTrustedApplicationCopyData(app, &mut data) == 0 && !data.is_null() {
            let bytes = std::slice::from_raw_parts(CFDataGetBytePtr(data), CFDataGetLength(data) as usize);
            let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
            out.push(format!("path:{}", String::from_utf8_lossy(&bytes[..end])));
            continue;
        }
        out.push("unreadable".into());
    }
    out.join(" | ")
}

// The partition entry's description is a hex-encoded plist listing the partition IDs.
fn partitions_of(hex: &str) -> String {
    let bytes: Option<Vec<u8>> = (0..hex.len() / 2)
        .map(|i| hex.get(2 * i..2 * i + 2).and_then(|p| u8::from_str_radix(p, 16).ok()))
        .collect();
    let Some(bytes) = bytes else { return hex.chars().take(60).collect() };
    let text = String::from_utf8_lossy(&bytes).into_owned();
    let mut out = Vec::new();
    let mut rest = text.as_str();
    while let Some(i) = rest.find("<string>") {
        rest = &rest[i + "<string>".len()..];
        let Some(j) = rest.find("</string>") else { break };
        out.push(rest[..j].to_string());
        rest = &rest[j..];
    }
    if out.is_empty() {
        "none".into()
    } else {
        out.join(",")
    }
}

unsafe fn cmd_acl(o: &Opts) -> i32 {
    watchdog(o);
    let Some(kc) = open_keychain(o, true) else { return 1 };
    let Some(q) = item_query(o, kc, false) else { return 1 };
    set(q, kSecReturnRef, kCFBooleanTrue.cast());
    let mut item: CFTypeRef = null();
    let st = SecItemCopyMatching(q.cast_const(), &mut item);
    let mut access: SecAccessRef = null_mut();
    let st = if st == 0 { extra::SecKeychainItemCopyAccess(item as SecKeychainItemRef, &mut access) } else { st };
    let mut list: CFArrayRef = null();
    let st = if st == 0 { extra::SecAccessCopyACLList(access, &mut list) } else { st };
    if st != 0 {
        emit(o, status_fields(st));
        return 1;
    }
    for i in 0..CFArrayGetCount(list) {
        let acl = CFArrayGetValueAtIndex(list, i);
        let auths = strings_of(extra::SecACLCopyAuthorizations(acl));
        let auths: Vec<String> = auths.iter().map(|a| a.trim_start_matches("ACLAuthorization").to_string()).collect();
        let mut apps: CFArrayRef = null();
        let mut desc: CFStringRef = null();
        let mut prompt = 0u16;
        let st = extra::SecACLCopyContents(acl, &mut apps, &mut desc, &mut prompt);
        let mut f = vec![("entry", i.to_string()), ("authorizations", auths.join(","))];
        if st != 0 {
            f.extend(status_fields(st));
        } else if auths.iter().any(|a| a == "PartitionID") {
            f.push(("partitions", partitions_of(&string_of(desc))));
        } else {
            f.push(("apps", apps_text(apps)));
            f.push(("prompt", format!("0x{prompt:04x}")));
        }
        emit(o, f);
    }
    0
}

unsafe fn report_status(o: &Opts, kc: SecKeychainRef) -> i32 {
    let mut s = 0u32;
    let st = extra::SecKeychainGetStatus(kc, &mut s);
    let yes = |bit: u32| if s & bit != 0 { "yes" } else { "no" }.to_string();
    let mut f = status_fields(st);
    f.push(("unlocked", yes(extra::kSecUnlockStateStatus)));
    f.push(("readable", yes(extra::kSecReadPermStatus)));
    f.push(("writable", yes(extra::kSecWritePermStatus)));
    let mut settings = SecKeychainSettings {
        version: SEC_KEYCHAIN_SETTINGS_VERS1,
        lockOnSleep: 0,
        useLockInterval: 0,
        lockInterval: 0,
    };
    let st2 = extra::SecKeychainCopySettings(kc, &mut settings);
    f.push(("settings_status", format!("{st2}:{}", status_name(st2))));
    if st2 == 0 {
        f.push(("lock_on_sleep", (settings.lockOnSleep != 0).to_string()));
        f.push(("use_lock_interval", (settings.useLockInterval != 0).to_string()));
        f.push(("lock_interval_s", settings.lockInterval.to_string()));
    }
    emit(o, f);
    i32::from(st != 0)
}

unsafe fn cmd_status(o: &Opts) -> i32 {
    watchdog(o);
    let Some(kc) = open_keychain(o, false) else { return 1 };
    report_status(o, kc)
}

unsafe fn cmd_lock(o: &Opts) -> i32 {
    let Some(kc) = open_keychain(o, false) else { return 1 };
    let st = extra::SecKeychainLock(kc);
    emit(o, status_fields(st));
    i32::from(st != 0)
}

fn read_password() -> Vec<u8> {
    let mut saved: libc::termios = unsafe { std::mem::zeroed() };
    let tty = unsafe { libc::tcgetattr(0, &mut saved) } == 0;
    if tty {
        let mut quiet = saved;
        quiet.c_lflag &= !libc::ECHO;
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &quiet) };
    }
    eprint!("keychain-probe: this account's login password (not echoed): ");
    let mut pw = Vec::new();
    let mut byte = [0u8; 1];
    let mut stdin = std::io::stdin();
    while stdin.read(&mut byte).is_ok_and(|n| n == 1) && byte[0] != b'\n' {
        pw.push(byte[0]);
    }
    if tty {
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &saved) };
        eprintln!();
    }
    pw
}

// SecKeychainUnlock takes the keychain's own password: for the login keychain, the macOS login
// password, not lendk's passphrase. --no-password asks the system to prompt instead.
unsafe fn cmd_unlock(o: &Opts) -> i32 {
    watchdog(o);
    let Some(kc) = open_keychain(o, false) else { return 1 };
    let started = Instant::now();
    let st = if o.no_password {
        SecKeychainUnlock(kc, 0, null(), 0)
    } else {
        let mut pw = read_password();
        let st = SecKeychainUnlock(kc, pw.len() as u32, pw.as_ptr().cast(), 1);
        pw.fill(0);
        st
    };
    let mut f = status_fields(st);
    f.push(("password", if o.no_password { "none" } else { "typed" }.into()));
    f.push(("elapsed_ms", started.elapsed().as_millis().to_string()));
    emit(o, f);
    i32::from(st != 0)
}

// --login-password makes the keychain with this account's login password read from stdin, for
// #36's stand-in login keychain on an account that never logged in at the GUI.
unsafe fn cmd_tempkc_create(o: &Opts) -> i32 {
    let Ok(path) = CString::new(o.keychain.as_str()) else { return 2 };
    let mut pw = if o.login_password { read_password() } else { TEST_KEYCHAIN_PASSWORD.as_bytes().to_vec() };
    let mut kc: SecKeychainRef = null_mut();
    let st = SecKeychainCreate(path.as_ptr(), pw.len() as u32, pw.as_ptr().cast(), 0, null_mut(), &mut kc);
    pw.fill(0);
    let mut f = vec![("step", "SecKeychainCreate".into())];
    f.extend(status_fields(st));
    emit(o, f);
    if st != 0 {
        return 1;
    }
    // The settings a new keychain starts with, before anyone changes them.
    report_status(o, kc)
}

unsafe fn cmd_tempkc_delete(o: &Opts) -> i32 {
    let Some(kc) = open_keychain(o, false) else { return 1 };
    let st = extra::SecKeychainDelete(kc);
    let mut f = vec![("step", "SecKeychainDelete".into())];
    f.extend(status_fields(st));
    emit(o, f);
    i32::from(st != 0)
}

fn cmd_memlock(o: &Opts) -> i32 {
    let mut r = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    unsafe { libc::getrlimit(libc::RLIMIT_MEMLOCK, &mut r) };
    let show = |v: libc::rlim_t| if v == libc::RLIM_INFINITY { "unlimited".into() } else { v.to_string() };
    emit(o, vec![("rlimit_memlock_soft", show(r.rlim_cur)), ("rlimit_memlock_hard", show(r.rlim_max))]);
    for size in [4usize << 10, 64 << 10, 1 << 20, 8 << 20, 64 << 20] {
        let p = unsafe {
            libc::mmap(null_mut(), size, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_PRIVATE | libc::MAP_ANON, -1, 0)
        };
        let result = if p == libc::MAP_FAILED {
            "mmap-failed".into()
        } else if unsafe { libc::mlock(p, size) } == 0 {
            unsafe { libc::munlock(p, size) };
            "ok".into()
        } else {
            std::io::Error::last_os_error().to_string()
        };
        if p != libc::MAP_FAILED {
            unsafe { libc::munmap(p, size) };
        }
        emit(o, vec![("bytes", size.to_string()), ("mlock", result)]);
    }
    0
}

unsafe fn cmd_info(o: &Opts) -> i32 {
    let mut allowed = 0u8;
    let st = SecKeychainGetUserInteractionAllowed(&mut allowed);
    let mut sid = 0u32;
    let mut attrs = 0u32;
    let st2 = extra::SessionGetInfo(extra::callerSecuritySession, &mut sid, &mut attrs);
    let yes = |bit: u32| if attrs & bit != 0 { "yes" } else { "no" }.to_string();
    let exe = std::env::current_exe().map(|p| p.display().to_string()).unwrap_or_default();
    emit(
        o,
        vec![
            ("exe", exe),
            ("uid", libc::getuid().to_string()),
            ("interaction_allowed_at_start", format!("{}:{}", st, allowed != 0)),
            ("session_status", st2.to_string()),
            ("session_id", format!("0x{sid:x}")),
            ("session_attrs", format!("0x{attrs:x}")),
            ("graphic_access", yes(extra::sessionHasGraphicAccess)),
            ("tty", yes(extra::sessionHasTTY)),
            ("remote", yes(extra::sessionIsRemote)),
            ("root", yes(extra::sessionIsRoot)),
        ],
    );
    let mut kc: SecKeychainRef = null_mut();
    let st = SecKeychainCopyDefault(&mut kc);
    let mut buf = [0 as c_char; 1024];
    let mut len = buf.len() as u32;
    let path = if st == 0 && extra::SecKeychainGetPath(kc, &mut len, buf.as_mut_ptr()) == 0 {
        std::ffi::CStr::from_ptr(buf.as_ptr()).to_string_lossy().into_owned()
    } else {
        "-".into()
    };
    let mut f = vec![("default_keychain", path)];
    f.extend(status_fields(st));
    emit(o, f);
    0
}

fn main() {
    let o = match parse() {
        Ok(o) => o,
        Err(e) => {
            eprintln!("keychain-probe: {e}");
            std::process::exit(2);
        }
    };
    if !std::path::Path::new(&format!("{}/{GUARD}", home())).exists() {
        eprintln!("keychain-probe: refusing to run: $HOME/{GUARD} is missing; run this on a throwaway account, see README.md");
        std::process::exit(2);
    }
    let code = unsafe {
        // `info` reports the process's initial setting, so it sets nothing.
        if o.suppress == Suppress::Flag && o.cmd != "info" {
            SecKeychainSetUserInteractionAllowed(0);
        }
        match o.cmd.as_str() {
            "info" => cmd_info(&o),
            "memlock" => cmd_memlock(&o),
            "status" => cmd_status(&o),
            "read" => cmd_read(&o),
            "write" => cmd_write(&o),
            "delete" => cmd_delete(&o),
            "acl" => cmd_acl(&o),
            "lock" => cmd_lock(&o),
            "unlock" => cmd_unlock(&o),
            "tempkc-create" => cmd_tempkc_create(&o),
            "tempkc-delete" => cmd_tempkc_delete(&o),
            other => {
                eprintln!("keychain-probe: unknown command: {other}");
                2
            }
        }
    };
    std::process::exit(code);
}
