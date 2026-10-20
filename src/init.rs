//! `lendk init`: the login block that puts the shim directory first on PATH.

use crate::edit::{Call, Outcome};
use crate::failure::Failure;
use crate::shims;

/// `lendk init sh|bash|zsh|systemd`: the login block holding the absolute shim directory. It
/// reads no map, and prints no code for a shim directory open to others.
pub fn init(call: &Call, words: &[&[u8]]) -> Outcome {
    let [shell] = words else {
        return Err(Failure::new("usage", "init takes one of sh, bash, zsh or systemd").into());
    };
    if ![&b"sh"[..], b"bash", b"zsh", b"systemd"].contains(shell) {
        let text = [
            b"init takes one of sh, bash, zsh or systemd, not '",
            *shell,
            b"'",
        ]
        .concat();
        return Err(Failure::new("usage", text).into());
    }
    let shims = &call.paths.shims;
    let dir = if shims.starts_with(b"/") {
        shims.clone()
    } else {
        shims::absolute(call.env, shims)
    };
    shims::check_dir(&dir)?;
    let block = |body: &[u8]| [b"# >>> lendk >>>\n", body, b"\n# <<< lendk <<<\n"].concat();
    if *shell == b"systemd" {
        return Ok((block(&[b"PATH=", &dir[..], b":${PATH}"].concat()), 0));
    }
    let mut q = b"'".to_vec();
    for &c in &dir {
        if c == b'\'' {
            q.extend_from_slice(b"'\\''");
        } else {
            q.push(c);
        }
    }
    q.push(b'\'');
    // The loop keeps every other entry, empty ones included, in order.
    let front = [
        &b"lendk_p=; lendk_r=${PATH:+$PATH:}\nwhile [ -n \"$lendk_r\" ]; do\n\tlendk_d=${lendk_r%%:*}; lendk_r=${lendk_r#*:}\n\t[ \"$lendk_d\" = "[..],
        &q,
        b" ] || lendk_p=$lendk_p:$lendk_d\ndone\nPATH=",
        &q,
        b"$lendk_p; export PATH\nunset lendk_p lendk_r lendk_d",
    ]
    .concat();
    let (head, tail): (&[u8], &[u8]) = match *shell {
        b"bash" => (
            b"__lendk_path() {\n",
            b"\nhash -r\n}\n__lendk_path\ncase \";${PROMPT_COMMAND-};\" in *\";__lendk_path;\"*) ;; *) PROMPT_COMMAND=\"__lendk_path${PROMPT_COMMAND:+;$PROMPT_COMMAND}\" ;; esac",
        ),
        b"zsh" => (
            b"__lendk_path() {\n",
            b"\nrehash\n}\n__lendk_path\n(( ${+precmd_functions} )) || typeset -ga precmd_functions; (( ${precmd_functions[(Ie)__lendk_path]} )) || precmd_functions+=(__lendk_path)",
        ),
        _ => (b"", b""),
    };
    Ok((block(&[head, &front, tail].concat()), 0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::Env;
    use crate::map::Paths;
    use std::ffi::CStr;

    fn init_with(shims: &'static CStr, shell: &[u8]) -> Vec<u8> {
        let entries = [shims, c"HOME=/nonexistent"];
        let env = Env(&entries);
        let paths = Paths::new(&env);
        let call = Call {
            env: &env,
            paths: &paths,
            interactive: false,
            argv0: b"lendk",
        };
        let Ok((out, 0)) = init(&call, &[shell]) else {
            panic!("init failed");
        };
        out
    }

    #[test]
    fn init_quotes_the_shim_directory_for_sh_and_leaves_systemd_unquoted() {
        let sh = "# >>> lendk >>>
lendk_p=; lendk_r=${PATH:+$PATH:}
while [ -n \"$lendk_r\" ]; do
\tlendk_d=${lendk_r%%:*}; lendk_r=${lendk_r#*:}
\t[ \"$lendk_d\" = '/nonexistent/it'\\''s' ] || lendk_p=$lendk_p:$lendk_d
done
PATH='/nonexistent/it'\\''s'$lendk_p; export PATH
unset lendk_p lendk_r lendk_d
# <<< lendk <<<
";
        let shims = c"LENDK_SHIMS=/nonexistent/it's";
        assert_eq!(String::from_utf8_lossy(&init_with(shims, b"sh")), sh);
        assert_eq!(
            init_with(shims, b"systemd"),
            b"# >>> lendk >>>\nPATH=/nonexistent/it's:${PATH}\n# <<< lendk <<<\n"
        );
    }
}
