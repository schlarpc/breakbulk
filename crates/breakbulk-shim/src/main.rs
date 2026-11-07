//! breakbulk-shim: the rustc wrapper, rustdoc wrapper and build-script stub
//! that let `breakbulk-plan` trace Cargo without compiling anything.
//!
//! Modes (see "breakbulk-shim modes" in docs/implementation.md):
//!
//! | Mode | Detected by | Action |
//! | --- | --- | --- |
//! | Build-script stub | `breakbulk-stub.json` beside the running executable | record env, print sentinels |
//! | Rustdoc | the executable's file name contains `rustdoc` | queries go to the real rustdoc; otherwise record, exit 0 |
//! | Query | `-vV`, `-V`, `--version`, any `--print`, or `-` as input | record (env = Cargo's own env), then `exec` the real rustc |
//! | Compile | `--crate-name` and an input file | record, fake outputs |
//!
//! As `RUSTC_WRAPPER` the shim is started as `shim [workspace-wrapper] rustc ARGS…`.
//! As `RUSTDOC` it must be started through a path whose file name contains
//! `rustdoc` (the planner makes a `rustdoc` symlink to the shim), and finds the
//! real rustdoc in `$BREAKBULK_RUSTDOC`.
//!
//! Environment:
//! - `BREAKBULK_RECORD`: directory for records (required for compile and rustdoc).
//! - `BREAKBULK_RUSTDOC`: the real rustdoc (rustdoc mode).
//! - `BREAKBULK_METADATA`: `cargo metadata` JSON for stubs (default `$BREAKBULK_RECORD/metadata.json`).

mod args;
mod compile;
mod record;
mod stub;

use args::RustcArgs;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

pub const RECORD_ENV: &str = "BREAKBULK_RECORD";
pub const RUSTDOC_ENV: &str = "BREAKBULK_RUSTDOC";

#[derive(Debug)]
pub struct Error(String);

impl Error {
    pub fn new(msg: impl Into<String>) -> Error {
        Error(msg.into())
    }
    pub fn io(path: &Path, e: std::io::Error) -> Error {
        Error(format!("{}: {e}", path.display()))
    }
}

fn record_dir() -> Result<PathBuf, Error> {
    std::env::var_os(RECORD_ENV)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| Error::new(format!("{RECORD_ENV} is not set")))
}

/// Replaces this process with `program args` (or runs it and forwards its
/// exit status where `exec` is unavailable).
fn exec(program: &[String], args: &[String]) -> Result<ExitCode, Error> {
    let mut cmd = Command::new(&program[0]);
    cmd.args(&program[1..]).args(args);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let e = cmd.exec();
        Err(Error::new(format!("exec {}: {e}", program[0])))
    }
    #[cfg(not(unix))]
    {
        let status = cmd
            .status()
            .map_err(|e| Error::new(format!("{}: {e}", program[0])))?;
        Ok(ExitCode::from(status.code().unwrap_or(1) as u8))
    }
}

/// Splits `[wrapper…, rustc, args…]`: the program chain is every leading
/// argument that is not an option. Cargo always starts rustc's arguments with
/// an option (`--crate-name`, `-vV`, `-`, `--print…`).
fn split_chain(argv: &[String]) -> (Vec<String>, Vec<String>) {
    let n = argv.iter().take_while(|a| !a.starts_with('-')).count();
    (argv[..n].to_vec(), argv[n..].to_vec())
}

fn is_rustdoc_invocation(argv0: &OsString) -> bool {
    Path::new(argv0)
        .file_name()
        .is_some_and(|f| f.to_string_lossy().contains("rustdoc"))
}

fn rustdoc_mode(args: Vec<String>) -> Result<ExitCode, Error> {
    let real =
        std::env::var(RUSTDOC_ENV).map_err(|_| Error::new(format!("{RUSTDOC_ENV} is not set")))?;
    let query = args.iter().any(|a| {
        matches!(a.as_str(), "-vV" | "-Vv" | "-V" | "--version") || a.starts_with("--print")
    });
    if query {
        return exec(&[real], &args);
    }
    let dir = record_dir()?;
    let mut rec = record::base("rustdoc", &[real], &args);
    let a = RustcArgs::parse(&args);
    rec.insert("crateName".into(), serde_json::json!(a.crate_name));
    rec.insert(
        "test".into(),
        serde_json::json!(args.iter().any(|a| a == "--test")),
    );
    let label = a.crate_name.clone().unwrap_or_else(|| "rustdoc".into());
    record::write(&dir, "rustdoc", &label, rec)
        .map_err(|e| Error::new(format!("writing record: {e}")))?;
    Ok(ExitCode::SUCCESS)
}

fn wrapper_mode(argv: Vec<String>) -> Result<ExitCode, Error> {
    let (program, args) = split_chain(&argv);
    if program.is_empty() {
        return Err(Error::new(
            "expected to be started as RUSTC_WRAPPER (`breakbulk-shim rustc ARGS`), as RUSTDOC, or as a build-script stub",
        ));
    }
    let a = RustcArgs::parse(&args);
    if a.is_query || a.crate_name.is_none() || a.input.is_none() {
        // Queries are recorded too: their env is Cargo's own process env
        // (Cargo adds nothing to it), which is the baseline the planner
        // subtracts. It includes variables Cargo sets on itself at startup,
        // such as SSL_CERT_FILE from openssl-probe.
        if let Ok(dir) = record_dir() {
            let rec = record::base("query", &program, &args);
            record::write(&dir, "query", "rustc", rec)
                .map_err(|e| Error::new(format!("writing record: {e}")))?;
        }
        return exec(&program, &args);
    }
    compile::run(&record_dir()?, &program, &args, &a)?;
    Ok(ExitCode::SUCCESS)
}

fn real_main() -> Result<ExitCode, Error> {
    if let Some((marker_path, marker)) = stub::detect() {
        stub::run(&marker_path, &marker)?;
        return Ok(ExitCode::SUCCESS);
    }
    let mut it = std::env::args_os();
    let argv0 = it.next().unwrap_or_default();
    let rest: Vec<String> = it.map(|a| a.to_string_lossy().into_owned()).collect();
    if is_rustdoc_invocation(&argv0) {
        return rustdoc_mode(rest);
    }
    wrapper_mode(rest)
}

fn main() -> ExitCode {
    match real_main() {
        Ok(c) => c,
        Err(Error(msg)) => {
            eprintln!("breakbulk-shim: {msg}");
            ExitCode::from(101)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chain() {
        let v = |s: &[&str]| s.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        let (p, a) = split_chain(&v(&[
            "/bin/clippy-driver",
            "/bin/rustc",
            "--crate-name",
            "x",
        ]));
        assert_eq!(p, ["/bin/clippy-driver", "/bin/rustc"]);
        assert_eq!(a, ["--crate-name", "x"]);
        let (p, a) = split_chain(&v(&["/bin/rustc", "-vV"]));
        assert_eq!((p.len(), a.len()), (1, 1));
    }
}
