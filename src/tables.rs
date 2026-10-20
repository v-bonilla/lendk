//! The public interface, defined once: the verbs, the map grammar, the name lists, the classes
//! and the variables. `--help` prints them, and 1.x's frozen lists in `test/frozen/` hold them.

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

// lint: tables begin
pub const VERBS: &[&str] = &[
    "lendk run [KEY|@GROUP...] -- CMD [ARG...]      # exec CMD with its mapped or the named keys",
    "lendk add [--force] CMD|@GROUP KEY|@GROUP...   # map, then sync",
    "lendk rm CMD|@GROUP [KEY|@GROUP...]            # unmap, then sync",
    "lendk check [NAME...]                          # diagnose without decrypting",
    "lendk sync                                     # write shims to match the map",
    "lendk unlock [KEY|@GROUP...]                   # unlock in a terminal; probe elsewhere",
    "lendk init sh|bash|zsh|systemd                 # print PATH setup",
    "lendk upgrade                                  # replace lendk with the latest release, then sync",
    "lendk --help | --version",
];

pub const GRAMMAR: &[&str] = &[
    "One entry per line; fields split on blanks; # starts a comment anywhere; blank lines are ignored.",
    "@NAME KEY...   defines a group of keys; NAME matches [A-Za-z0-9_-]+",
    "CMD WORD...    maps a command; WORD is a KEY or @NAME; CMD matches [A-Za-z0-9_+][A-Za-z0-9._+-]*",
    "KEY matches [A-Za-z_][A-Za-z0-9_]*; its value is the first line of store entry PREFIX/KEY.",
    "Denied keys: the prefixes and names below; LENDK_ in any case.",
    "Each CMD and group appears once; a group may be used before its definition.",
    "Expansion follows word order, inlines groups, and drops duplicates, keeping the first.",
    "Guarded commands are mapped only with add --force: their keys reach every program they run.",
];

pub const RESERVED_CMDS: &[&str] = &[
    "lendk",
    "bash",
    "pass",
    "gpg",
    "gpg2",
    "gpg-agent",
    "gpgconf",
];
pub const DENIED_PREFIXES: &[&str] = &[
    "BASH",
    "LENDK_",
    "PASSWORD_STORE_",
    "GNUPG",
    "GPG_",
    "LD_",
    "DYLD_",
    "LC_",
    "XDG_",
];
pub const DENIED_NAMES: &[&str] = &[
    "PATH",
    "HOME",
    "SHELL",
    "ENV",
    "IFS",
    "CDPATH",
    "PS4",
    "PROMPT_COMMAND",
    "TMPDIR",
    "USER",
    "LOGNAME",
    "LANG",
    "TERM",
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "DBUS_SESSION_BUS_ADDRESS",
    "PINENTRY_USER_DATA",
    "SHELLOPTS",
    "UID",
    "EUID",
    "PPID",
    "GROUPS",
    "RANDOM",
    "SRANDOM",
    "SECONDS",
    "LINENO",
    "HISTCMD",
    "EPOCHSECONDS",
    "EPOCHREALTIME",
    "FUNCNAME",
    "DIRSTACK",
    "PIPESTATUS",
    "OPTIND",
    "OPTARG",
];
pub const GUARDED_SHELLS: &[&str] = &[
    "sh", "dash", "zsh", "ksh", "mksh", "fish", "csh", "tcsh", "busybox",
];
pub const GUARDED_INTERPRETERS: &[&str] = &[
    "python*", "pypy*", "node", "nodejs", "deno", "bun", "perl*", "ruby*", "php*", "lua*", "java",
];
pub const GUARDED_LAUNCHERS: &[&str] = &[
    "env", "sudo", "doas", "su", "xargs", "nohup", "setsid", "timeout", "nice", "make", "tmux",
    "screen",
];
pub const GUARDED_PACKAGE_TOOLS: &[&str] = &[
    "npm", "npx", "pnpm", "yarn", "pip", "pip3", "pipx", "uv", "uvx",
];
pub const GUARDED_AGENT_CLIS: &[&str] =
    &["aider", "claude", "codex", "gemini", "goose", "opencode"];

pub const LISTS: &[(&str, &[&str])] = &[
    ("reserved commands", RESERVED_CMDS),
    ("denied key prefixes", DENIED_PREFIXES),
    ("denied key names", DENIED_NAMES),
    ("guarded shells", GUARDED_SHELLS),
    ("guarded interpreters", GUARDED_INTERPRETERS),
    ("guarded launchers", GUARDED_LAUNCHERS),
    ("guarded package tools", GUARDED_PACKAGE_TOOLS),
    ("guarded agent CLIs", GUARDED_AGENT_CLIS),
];

/// A class row. A class with two TEXT forms has two rows, keyed `CLASS` and `CLASS:FORM`.
pub struct Class {
    pub id: &'static str,
    pub hint: u8,
    pub interactive: &'static str,
    pub non_interactive: &'static str,
}

const UNLOCK_FIX: &str = "Ask the user to run 'lendk unlock KEY' in a terminal, then retry.";
const STOP_FIX: &str = "Stop and ask the user.";
const REINSTALL_FIX: &str =
    "The user must reinstall lendk from its project repository, then run: lendk sync";

const fn class(
    id: &'static str,
    hint: u8,
    interactive: &'static str,
    non_interactive: &'static str,
) -> Class {
    Class {
        id,
        hint,
        interactive,
        non_interactive,
    }
}

pub const CLASSES: &[Class] = &[
    class("usage", 2, "See: lendk --help", "See: lendk --help"),
    class(
        "guarded",
        2,
        "To map it anyway: lendk add --force CMD WORD...",
        STOP_FIX,
    ),
    class(
        "unsupported",
        125,
        "Put a newer bash first on PATH.",
        STOP_FIX,
    ),
    class("unsupported:gnupg", 125, "Upgrade GnuPG.", STOP_FIX),
    class("locked", 120, UNLOCK_FIX, UNLOCK_FIX),
    class("canceled", 120, "Run the command again to retry.", STOP_FIX),
    class(
        "timeout",
        120,
        "Retry; a hardware token may need a touch, or raise LENDK_TIMEOUT.",
        UNLOCK_FIX,
    ),
    class("map", 125, "Fix the line, then run: lendk check", STOP_FIX),
    class(
        "map:group",
        125,
        "Define it first: lendk add @GROUP KEY...",
        STOP_FIX,
    ),
    class(
        "unmapped",
        125,
        "Map it: lendk add CMD KEY..., or name keys: lendk run KEY... -- CMD",
        STOP_FIX,
    ),
    class("missing-key", 125, "Add it: pass insert env/KEY", STOP_FIX),
    class(
        "missing-key:nomap",
        125,
        "Create it with lendk add, or name the keys to unlock.",
        STOP_FIX,
    ),
    class(
        "missing-key:none",
        125,
        "Add a mapped key with pass insert, then retry.",
        STOP_FIX,
    ),
    class(
        "missing-key:empty",
        125,
        "Set it: pass edit env/KEY",
        STOP_FIX,
    ),
    class(
        "decrypt",
        125,
        "See gpg's error: lendk unlock KEY",
        UNLOCK_FIX,
    ),
    class(
        "unsafe",
        125,
        "Fix it: chmod go-w PATH, or recreate it as your own",
        STOP_FIX,
    ),
    class("write", 125, "Fix it, then run: lendk sync", STOP_FIX),
    class(
        "upgrade",
        125,
        "Retry; on a slow connection raise LENDK_TIMEOUT.",
        STOP_FIX,
    ),
    class(
        "upgrade:install",
        125,
        "Upgrade lendk the way it was installed.",
        STOP_FIX,
    ),
    class(
        "upgrade:local",
        125,
        "Fix it, then run: lendk upgrade",
        STOP_FIX,
    ),
    class("exec", 126, "Fix it, or unmap it: lendk rm CMD", STOP_FIX),
    class(
        "not-found",
        127,
        "Install it, or unmap it: lendk rm CMD",
        "Install CMD, or ask the user.",
    ),
    class("lendk-missing", 127, REINSTALL_FIX, REINSTALL_FIX),
];

pub const VARIABLES: &[(&str, &str)] = &[
    (
        "LENDK_MAP",
        "map file; default ${XDG_CONFIG_HOME:-~/.config}/lendk/map",
    ),
    (
        "LENDK_SHIMS",
        "shim directory, set wherever lendk runs; default ${XDG_DATA_HOME:-~/.local/share}/lendk/shims; lock: SHIMS.lock",
    ),
    ("LENDK_PREFIX", "store entry prefix; default env"),
    ("LENDK_PROMPT", "auto (default), never or allow"),
    (
        "LENDK_TIMEOUT",
        "seconds of backend work, or of upgrade's fetch, per call, 1 to 3600; default 60 interactive, 10 otherwise",
    ),
    (
        "LENDK_INSTALL_BASE_URL",
        "release base for upgrade and install.sh, https:// or file:///; default https://github.com/v-bonilla/lendk/releases",
    ),
    (
        "LENDK_INJECTED",
        "set by lendk for targets: the names injected, space-separated",
    ),
    ("PASSWORD_STORE_DIR", "store; default ~/.password-store"),
    (
        "XDG_CONFIG_HOME",
        "base of the default map; relative values are ignored",
    ),
    (
        "XDG_DATA_HOME",
        "base of the default shim directory; relative values are ignored",
    ),
    ("GPG_TTY", "set by lendk for the backend only"),
];
// lint: tables end

/// The text `lendk --help` prints.
pub fn help() -> String {
    let mut out = format!(
        "lendk {VERSION}: give API keys stored in pass to the commands that need them, only while they run.\n\nUsage:\n"
    );
    for verb in VERBS {
        out += &format!("  {verb}\n");
    }
    out += "\n--force is the only flag. Shims call: lendk run -- CMD. After a hand edit of the map, run: lendk sync\n";
    out += "\nMap file (LENDK_MAP):\n";
    for line in GRAMMAR {
        out += &format!("  {line}\n");
    }
    out += "\nName lists:\n";
    for (label, words) in LISTS {
        out += &format!("  {label}: {}\n", words.join(" "));
    }
    out +=
        "\nClasses: lendk: CLASS: TEXT. FIX (exit hint): interactive FIX | non-interactive FIX\n";
    for c in CLASSES {
        let name = c.id.split(':').next().unwrap_or(c.id);
        out += &format!(
            "  {name} ({}): {} | {}\n",
            c.hint, c.interactive, c.non_interactive
        );
    }
    out += "  notice: a change or a risk, never a failure\n";
    out += "\nExit: 0 success; 1 check found a problem; after exec, the command's own status.\n";
    out += "\nEnvironment:\n";
    for (name, text) in VARIABLES {
        out += &format!("  {name:<22} {text}\n");
    }
    out
}
