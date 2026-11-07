//! Running child processes and describing how they ended.

use std::collections::BTreeMap;
use std::path::Path;
use std::process::{Command, ExitStatus};

/// A command with exactly the given environment and working directory.
pub fn command(argv: &[String], env: &BTreeMap<String, String>, cwd: &Path) -> Command {
    let mut cmd = Command::new(&argv[0]);
    cmd.args(&argv[1..]).env_clear().envs(env).current_dir(cwd);
    cmd
}

/// The conventional name of a signal number on Linux, or `None` for numbers
/// without one. The numbers are the generic Linux ones (x86, Arm, RISC-V);
/// other platforms report only the number.
pub fn signal_name(sig: i32) -> Option<&'static str> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    Some(match sig {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        4 => "SIGILL",
        5 => "SIGTRAP",
        6 => "SIGABRT",
        7 => "SIGBUS",
        8 => "SIGFPE",
        9 => "SIGKILL",
        10 => "SIGUSR1",
        11 => "SIGSEGV",
        12 => "SIGUSR2",
        13 => "SIGPIPE",
        14 => "SIGALRM",
        15 => "SIGTERM",
        16 => "SIGSTKFLT",
        17 => "SIGCHLD",
        18 => "SIGCONT",
        19 => "SIGSTOP",
        20 => "SIGTSTP",
        21 => "SIGTTIN",
        22 => "SIGTTOU",
        23 => "SIGURG",
        24 => "SIGXCPU",
        25 => "SIGXFSZ",
        26 => "SIGVTALRM",
        27 => "SIGPROF",
        28 => "SIGWINCH",
        29 => "SIGIO",
        30 => "SIGPWR",
        31 => "SIGSYS",
        _ => return None,
    })
}

/// How a process ended, in the style of Cargo's "process didn't exit
/// successfully" messages: `exit status: 1`, or `signal: 11, SIGSEGV` for a
/// process killed by a signal (with `, core dumped` when it was).
pub fn describe_status(status: &ExitStatus) -> String {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(sig) = status.signal() {
            let mut s = format!("signal: {sig}");
            if let Some(name) = signal_name(sig) {
                s.push_str(", ");
                s.push_str(name);
            }
            if status.core_dumped() {
                s.push_str(", core dumped");
            }
            return s;
        }
    }
    match status.code() {
        Some(c) => format!("exit status: {c}"),
        None => format!("{status}"),
    }
}

/// Quote a command line for messages, as a shell would need it.
pub fn shell_words(argv: &[String]) -> String {
    argv.iter()
        .map(|a| {
            if !a.is_empty()
                && a.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_./=:,+@%".contains(&b))
            {
                a.clone()
            } else {
                format!("'{}'", a.replace('\'', r"'\''"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn statuses() {
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(describe_status(&ExitStatus::from_raw(0)), "exit status: 0");
        assert_eq!(
            describe_status(&ExitStatus::from_raw(3 << 8)),
            "exit status: 3"
        );
        if cfg!(target_os = "linux") {
            assert_eq!(
                describe_status(&ExitStatus::from_raw(11)),
                "signal: 11, SIGSEGV"
            );
            assert_eq!(
                describe_status(&ExitStatus::from_raw(6 | 0x80)),
                "signal: 6, SIGABRT, core dumped"
            );
            assert_eq!(
                describe_status(&ExitStatus::from_raw(9)),
                "signal: 9, SIGKILL"
            );
        }
    }

    #[test]
    fn quoting() {
        assert_eq!(
            shell_words(&[
                "rustc".into(),
                "--cfg".into(),
                "feature=\"x\"".into(),
                "".into()
            ]),
            r#"rustc --cfg 'feature="x"' ''"#
        );
        assert_eq!(shell_words(&["it's".into()]), r"'it'\''s'");
    }
}
