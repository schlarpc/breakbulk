//! Just enough rustc command-line parsing to fake a compile.
//!
//! The shim never interprets flags beyond what it needs to name outputs. The
//! output names themselves come from rustc (`--print=file-names`); this module
//! finds the crate name, the requested emit kinds, the output directory and the
//! input file.

use std::path::{Path, PathBuf};

/// rustc options that take their value as the next argument when written
/// without `=`. Anything not listed is treated as a flag without a value.
/// Taken from `rustc --help` and `rustc -C help`/`-Z help` (all `-C`/`-Z`
/// options take a value).
const TAKES_VALUE: &[&str] = &[
    "-o",
    "-L",
    "-l",
    "-C",
    "-Z",
    "-W",
    "-A",
    "-D",
    "-F",
    "--cfg",
    "--check-cfg",
    "--crate-type",
    "--crate-name",
    "--edition",
    "--emit",
    "--print",
    "--out-dir",
    "--explain",
    "--target",
    "--cap-lints",
    "--extern",
    "--sysroot",
    "--error-format",
    "--json",
    "--color",
    "--diagnostic-width",
    "--remap-path-prefix",
    "--remap-path-scope",
    "--env-set",
    "--force-warn",
    "--warn",
    "--allow",
    "--deny",
    "--forbid",
    "--codegen",
];

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct RustcArgs {
    pub crate_name: Option<String>,
    pub crate_types: Vec<String>,
    /// `--emit` entries in the order given, each `(kind, explicit path)`.
    pub emit: Vec<(String, Option<String>)>,
    pub out_dir: Option<String>,
    pub output: Option<String>,
    pub extra_filename: String,
    pub input: Option<String>,
    /// `--json` contains `artifacts` (rustc then prints artifact notifications).
    pub json_artifacts: bool,
    /// Any `--print` request, `-vV`, `-V`, `--version`, or `-` as the input.
    pub is_query: bool,
    /// `--test` was given (libtest harness).
    pub test: bool,
}

/// Splits `--opt=value` / `-Cvalue` / `--opt value` forms. Returns the option
/// name, its value (if any) and how many argv entries were consumed.
fn split_opt(args: &[String], i: usize) -> (&str, Option<&str>, usize) {
    let a = args[i].as_str();
    if let Some(rest) = a.strip_prefix("--") {
        if let Some((name, value)) = rest.split_once('=') {
            return (&a[..2 + name.len()], Some(value), 1);
        }
        if TAKES_VALUE.contains(&a) {
            return (a, args.get(i + 1).map(String::as_str), 2);
        }
        return (a, None, 1);
    }
    if a.starts_with('-') && a.len() > 2 {
        // Short options with attached values: `-Cfoo=bar`, `-Ldependency=…`.
        let name = &a[..2];
        if TAKES_VALUE.contains(&name) {
            return (name, Some(&a[2..]), 1);
        }
        return (a, None, 1);
    }
    if TAKES_VALUE.contains(&a) {
        return (a, args.get(i + 1).map(String::as_str), 2);
    }
    (a, None, 1)
}

impl RustcArgs {
    pub fn parse(args: &[String]) -> RustcArgs {
        let mut r = RustcArgs::default();
        let mut i = 0;
        while i < args.len() {
            let a = &args[i];
            if a == "-" {
                r.is_query = true;
                i += 1;
                continue;
            }
            if !a.starts_with('-') {
                // A positional argument is the input file. rustc accepts only one.
                if r.input.is_none() {
                    r.input = Some(a.clone());
                }
                i += 1;
                continue;
            }
            let (name, value, used) = split_opt(args, i);
            match (name, value) {
                ("-vV" | "-Vv" | "-V" | "--version", _) => r.is_query = true,
                ("--print", _) => r.is_query = true,
                ("--test", _) => r.test = true,
                ("--crate-name", Some(v)) => r.crate_name = Some(v.to_string()),
                ("--crate-type", Some(v)) => r.crate_types.extend(v.split(',').map(str::to_string)),
                ("--emit", Some(v)) => {
                    for part in v.split(',') {
                        match part.split_once('=') {
                            Some((k, p)) => r.emit.push((k.to_string(), Some(p.to_string()))),
                            None => r.emit.push((part.to_string(), None)),
                        }
                    }
                }
                ("--out-dir", Some(v)) => r.out_dir = Some(v.to_string()),
                ("-o", Some(v)) => r.output = Some(v.to_string()),
                ("--json", Some(v)) => {
                    if v.split(',').any(|k| k == "artifacts") {
                        r.json_artifacts = true;
                    }
                }
                ("-C" | "--codegen", Some(v)) => {
                    if let Some(e) = v.strip_prefix("extra-filename=") {
                        r.extra_filename = e.to_string();
                    }
                }
                _ => {}
            }
            i += used;
        }
        r
    }

    /// Emit kinds in effect; rustc's default is `link`.
    pub fn emit_kinds(&self) -> Vec<(String, Option<String>)> {
        if self.emit.is_empty() {
            vec![("link".to_string(), None)]
        } else {
            self.emit.clone()
        }
    }

    pub fn emits(&self, kind: &str) -> bool {
        self.emit_kinds().iter().any(|(k, _)| k == kind)
    }

    /// Directory outputs go to: `--out-dir`, else the directory of `-o`, else `.`.
    pub fn out_dir(&self) -> PathBuf {
        if let Some(d) = &self.out_dir {
            return PathBuf::from(d);
        }
        if let Some(o) = &self.output
            && let Some(p) = Path::new(o).parent()
        {
            return p.to_path_buf();
        }
        PathBuf::from(".")
    }

    /// Output stem shared by rustc's non-link outputs: `<crate><extra>`.
    pub fn stem(&self) -> String {
        format!(
            "{}{}",
            self.crate_name.as_deref().unwrap_or_default(),
            self.extra_filename
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &[&str]) -> Vec<String> {
        s.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn cargo_lib_compile() {
        let a = RustcArgs::parse(&v(&[
            "--crate-name",
            "foo",
            "--edition=2021",
            "src/lib.rs",
            "--error-format=json",
            "--json=diagnostic-rendered-ansi,artifacts,future-incompat",
            "--crate-type",
            "lib",
            "--emit=dep-info,metadata,link",
            "-C",
            "embed-bitcode=no",
            "-C",
            "metadata=0123",
            "-C",
            "extra-filename=-0123",
            "--out-dir",
            "/t/debug/deps",
            "-L",
            "dependency=/t/debug/deps",
            "--extern",
            "bar=/t/debug/deps/libbar-1.rmeta",
            "--cfg",
            "feature=\"x\"",
        ]));
        assert_eq!(a.crate_name.as_deref(), Some("foo"));
        assert_eq!(a.input.as_deref(), Some("src/lib.rs"));
        assert_eq!(a.crate_types, ["lib"]);
        assert_eq!(a.extra_filename, "-0123");
        assert_eq!(a.out_dir(), PathBuf::from("/t/debug/deps"));
        assert!(a.json_artifacts && a.emits("metadata") && a.emits("link"));
        assert!(!a.is_query);
    }

    #[test]
    fn attached_forms() {
        let a = RustcArgs::parse(&v(&[
            "--crate-name=x",
            "-Cextra-filename=-9",
            "--emit",
            "metadata=/o/x.rmeta,link",
            "-Ldependency=/d",
            "main.rs",
        ]));
        assert_eq!(a.crate_name.as_deref(), Some("x"));
        assert_eq!(a.extra_filename, "-9");
        assert_eq!(
            a.emit,
            vec![
                ("metadata".into(), Some("/o/x.rmeta".into())),
                ("link".into(), None)
            ]
        );
        assert_eq!(a.input.as_deref(), Some("main.rs"));
    }

    #[test]
    fn queries() {
        assert!(RustcArgs::parse(&v(&["-vV"])).is_query);
        assert!(
            RustcArgs::parse(&v(&[
                "-",
                "--crate-name",
                "___",
                "--print=file-names",
                "--crate-type",
                "bin"
            ]))
            .is_query
        );
        assert!(RustcArgs::parse(&v(&["--print", "sysroot"])).is_query);
    }
}
