//! `breakbulk-unit doctest`: run one library's doctests.
//!
//! The doctest derivation of a library runs the test plan's traced
//! `rustdoc --test` command ("Tests" in
//! `docs/src/explanation/internals/products.md`). rustdoc
//! compiles every example against the crate's `rlib` and its dependencies,
//! then runs it, in one process; so there is no output but the log, and no
//! cutoff.
//!
//! The command is a compile unit's ([`RenderedCompile`], with no outputs and
//! no remapping), plus the one thing Cargo computes from values rather than
//! positions: the `-L` list of every build-script run's search paths
//! (`run_doc_tests` in Cargo's `src/cargo/ops/cargo_test.rs`, from
//! `Compilation::native_dirs`, a `BTreeSet<PathBuf>`). It is rebuilt here at
//! build time from the runs' `flags` outputs, sorted as Cargo sorts paths
//! (by component) and without duplicates, at the position the trace showed.
//!
//! Configuration from the derivation's environment, all optional:
//!
//! - [`RUNNER_VAR`]: a JSON array, the target's runner and its arguments.
//!   Passed as Cargo does, `--test-runtool R --test-runtool-arg A …` right
//!   after `--target T`.
//! - [`TEST_ARGS_VAR`]: a JSON array of libtest arguments, each passed as
//!   `--test-args A` after the `-L` list, where Cargo puts them.
//! - [`TEST_ENV_VAR`]: a JSON object of variables merged over the command's
//!   environment, list-like variables (`PATH`) appended
//!   ([`crate::env::merge_layer`]).
//!
//! - [`POST_RUN_VAR`]: a program run after passing doctests (the
//!   package's `test.postRun` snippets, `test.keepLog`'s copy), in
//!   `$TMPDIR`, with `log` and `out` set.
//!
//! `RUST_TEST_THREADS` is set to the job count ([`Outer::jobs`]) unless the
//! test env sets it. The combined stdout and stderr go to the build log and
//! to [`LOG_FILE`] in `$TMPDIR`, not `$out`: the output holds timings and
//! lines in a varying order, and `nix build --rebuild` compares `$out`,
//! which stays empty unless the post-run program fills it. The derivation
//! fails when rustdoc exits non-zero.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{ExitCode, Stdio};

use serde::{Deserialize, Serialize};

use crate::compile::{Invocation, check_args, fresh_dir, link_deps};
use crate::directives::BuildOutput;
use crate::env::{CFlags, Outer, capture_layer, layered, merge_layer};
use crate::process::{command, describe_status, shell_words};
use crate::spec::{RenderedArg, RenderedCompile};
use crate::splice::{check_arg_splices, expand_args, expand_env, prepend_dylib_path};
use crate::{Error, io_err, read_directives};

pub const RUNNER_VAR: &str = "BREAKBULK_TEST_RUNNER";
pub const TEST_ARGS_VAR: &str = "BREAKBULK_TEST_ARGS";
pub const TEST_ENV_VAR: &str = "BREAKBULK_TEST_ENV";

pub const POST_RUN_VAR: &str = "BREAKBULK_TEST_POST_RUN";

/// The log file in `$TMPDIR`.
pub const LOG_FILE: &str = "breakbulk-doctest.log";

/// `BREAKBULK_UNIT` of a doctest derivation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RenderedDoctest {
    /// Always `"doctest"`, so that the value cannot be mistaken for a unit.
    pub kind: DoctestKind,
    /// The traced `rustdoc --test`, without its `searchPathsOf` splice.
    /// `outputs` is empty and `remap` is empty: rustdoc writes nothing that
    /// is kept.
    pub compile: RenderedCompile,
    /// The `flags` outputs of the runs whose search paths form the `-L`
    /// list.
    pub search_paths_of: Vec<String>,
    /// Search paths that are no run's (`links` overrides), sorted into the
    /// same list.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub search_paths_literals: Vec<String>,
    /// Where in `compile.args` the `-L` list goes.
    pub search_paths_at: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DoctestKind {
    Doctest,
}

/// The configuration a doctest derivation adds to the traced command.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TestConfig {
    pub runner: Vec<String>,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub post_run: Option<String>,
}

impl TestConfig {
    pub fn from_outer(outer: &Outer) -> Result<TestConfig, Error> {
        fn parse<T: serde::de::DeserializeOwned + Default>(
            outer: &Outer,
            var: &str,
        ) -> Result<T, Error> {
            match outer.get(var).filter(|s| !s.trim().is_empty()) {
                None => Ok(T::default()),
                Some(s) => serde_json::from_str(s).map_err(|e| Error(format!("{var}: {e}"))),
            }
        }
        Ok(TestConfig {
            runner: parse(outer, RUNNER_VAR)?,
            args: parse(outer, TEST_ARGS_VAR)?,
            env: parse(outer, TEST_ENV_VAR)?,
            post_run: outer
                .get(POST_RUN_VAR)
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
        })
    }
}

/// Every search path of the given runs, both classes, and the `literals`
/// (search paths of `links` overrides), sorted and without duplicates as
/// Cargo's `BTreeSet<PathBuf>` holds them: by path component, with the
/// value as printed (`native=` prefix included).
pub fn search_paths<'a>(
    runs: &[String],
    literals: &[String],
    directives: impl Fn(&str) -> Option<&'a BuildOutput>,
) -> Result<Vec<String>, Error> {
    let mut set: BTreeSet<PathBuf> = literals.iter().map(PathBuf::from).collect();
    for r in runs {
        let d = directives(r)
            .ok_or_else(|| Error(format!("no directives for the search paths of {r}")))?;
        set.extend(d.library_paths.iter().map(|p| PathBuf::from(&p.value)));
    }
    set.into_iter()
        .map(|p| {
            p.into_os_string()
                .into_string()
                .map_err(|p| Error(format!("search path {p:?} is not UTF-8")))
        })
        .collect()
}

/// Read the `directives.json` of every run the doctest names.
fn load_directives(d: &RenderedDoctest) -> Result<BTreeMap<String, BuildOutput>, Error> {
    let flags: BTreeSet<&str> = d
        .compile
        .args
        .iter()
        .filter_map(|a| match a {
            RenderedArg::Splice(s) => Some(s.splice.as_str()),
            RenderedArg::Literal(_) => None,
        })
        .chain(d.compile.env_splices.iter().map(|s| s.splice.as_str()))
        .chain(d.compile.dylib_path_from.iter().map(String::as_str))
        .chain(d.search_paths_of.iter().map(String::as_str))
        .collect();
    flags
        .into_iter()
        .map(|f| Ok((f.to_owned(), read_directives(Path::new(f))?)))
        .collect()
}

/// The full command: the traced arguments with the runner after
/// `--target T`, the `-L` list and the test arguments at the traced
/// position, and the dependency directory last.
pub fn invocation(
    d: &RenderedDoctest,
    outer: &Outer,
    directives: &BTreeMap<String, BuildOutput>,
    config: &TestConfig,
    deps_dir: &Path,
) -> Result<Invocation, Error> {
    let c = &d.compile;
    check_args(c)?;
    if c.program.is_empty() {
        return Err(Error::new("the doctest has an empty program"));
    }
    if d.search_paths_at > c.args.len() {
        return Err(Error(format!(
            "searchPathsAt {} is past the end of the {} arguments",
            d.search_paths_at,
            c.args.len()
        )));
    }
    let splices: Vec<_> = c
        .args
        .iter()
        .enumerate()
        .filter_map(|(i, a)| match a {
            RenderedArg::Splice(s) => Some((i, s)),
            RenderedArg::Literal(_) => None,
        })
        .collect();
    check_arg_splices(&splices)?;
    let lookup = |f: &str| directives.get(f);
    let (before, after) = c.args.split_at(d.search_paths_at);
    let mut before = expand_args(before, lookup)?;
    let after = expand_args(after, lookup)?;

    let mut runtool = Vec::new();
    if let Some((tool, args)) = config.runner.split_first() {
        runtool.extend(["--test-runtool".to_owned(), tool.clone()]);
        for a in args {
            runtool.extend(["--test-runtool-arg".to_owned(), a.clone()]);
        }
    }
    let at = before
        .iter()
        .position(|a| a == "--target")
        .map_or(before.len(), |i| (i + 2).min(before.len()));
    before.splice(at..at, runtool);

    let mut argv = c.program.clone();
    argv.extend(before);
    for p in search_paths(&d.search_paths_of, &d.search_paths_literals, lookup)? {
        argv.extend(["-L".to_owned(), p]);
    }
    for a in &config.args {
        argv.extend(["--test-args".to_owned(), a.clone()]);
    }
    argv.extend(after);
    argv.extend([
        "-L".to_owned(),
        format!("dependency={}", deps_dir.display()),
    ]);

    let mut unit_env = expand_env(&c.env, &c.env_splices, lookup)?;
    prepend_dylib_path(&mut unit_env, &c.dylib_path_from, lookup)?;
    let capture = capture_layer(c.env_capture.as_deref(), &c.link_captures)?;
    let mut env = layered(outer, capture.as_ref(), &unit_env, &CFlags::default());
    env.insert("RUST_TEST_THREADS".into(), outer.jobs().to_string());
    merge_layer(&mut env, config.env.clone());
    Ok(Invocation {
        argv,
        env,
        cwd: PathBuf::from(&c.cwd),
    })
}

/// Run the command, copying its combined output to stderr and to `log`.
pub fn run_logged(inv: &Invocation, log: &Path) -> Result<std::process::ExitStatus, Error> {
    eprintln!("     Running `{}`", shell_words(&inv.argv));
    let mut file = std::fs::File::create(log).map_err(|e| io_err("creating", log, e))?;
    let (reader, writer) = std::io::pipe().map_err(|e| Error(format!("creating a pipe: {e}")))?;
    let writer2 = writer
        .try_clone()
        .map_err(|e| Error(format!("cloning a pipe: {e}")))?;
    let mut cmd = command(&inv.argv, &inv.env, &inv.cwd);
    cmd.stdin(Stdio::null()).stdout(writer).stderr(writer2);
    let mut child = cmd
        .spawn()
        .map_err(|e| Error(format!("could not start `{}`: {e}", inv.argv[0])))?;
    // The command holds the pipe's write ends; drop them so the read below
    // ends when the child exits.
    drop(cmd);
    {
        let mut err = std::io::stderr().lock();
        for line in BufReader::new(reader).split(b'\n') {
            let mut line = line.map_err(|e| Error(format!("reading the output: {e}")))?;
            line.push(b'\n');
            let _ = err.write_all(&line);
            file.write_all(&line)
                .map_err(|e| io_err("writing", log, e))?;
        }
    }
    child
        .wait()
        .map_err(|e| Error(format!("waiting for `{}`: {e}", inv.argv[0])))
}

/// The whole `doctest` mode.
pub fn doctest(d: &RenderedDoctest, outer: &Outer) -> Result<(), Error> {
    let config = TestConfig::from_outer(outer)?;
    let deps = outer.tmpdir().join("deps");
    let directives = load_directives(d)?;
    let inv = invocation(d, outer, &directives, &config, &deps)?;
    link_deps(&d.compile.deps, &deps)?;
    let out = outer.output("out")?;
    fresh_dir(&out)?;
    let log = outer.tmpdir().join(LOG_FILE);
    let status = run_logged(&inv, &log)?;
    if !status.success() {
        return Err(Error(format!(
            "doctests of `{}` failed ({})",
            d.compile.krate.name,
            describe_status(&status)
        )));
    }
    if let Some(program) = &config.post_run {
        post_run(program, outer, &log, &out)?;
    }
    Ok(())
}

/// Run the post-run program with the derivation's environment and `log`
/// and `out`.
fn post_run(program: &str, outer: &Outer, log: &Path, out: &Path) -> Result<(), Error> {
    let status = std::process::Command::new(program)
        .current_dir(outer.tmpdir())
        .env("log", log)
        .env("out", out)
        .stdin(Stdio::null())
        .status()
        .map_err(|e| Error(format!("could not start `{program}`: {e}")))?;
    if !status.success() {
        return Err(Error(format!(
            "the doctests' test.postRun failed ({})",
            describe_status(&status)
        )));
    }
    Ok(())
}

/// Read the doctest from `BREAKBULK_UNIT` or the file `BREAKBULK_UNITPath`.
pub fn read(outer: &Outer) -> Result<RenderedDoctest, Error> {
    let (text, whence) = if let Some(path) = outer.get("BREAKBULK_UNITPath") {
        let text =
            std::fs::read_to_string(path).map_err(|e| io_err("reading", Path::new(path), e))?;
        (text, format!("the file {path}"))
    } else if let Some(text) = outer.get("BREAKBULK_UNIT") {
        (text.to_owned(), "BREAKBULK_UNIT".to_owned())
    } else {
        return Err(Error::new(
            "neither BREAKBULK_UNIT nor BREAKBULK_UNITPath is set",
        ));
    };
    serde_json::from_str(&text).map_err(|e| Error(format!("invalid doctest in {whence}: {e}")))
}

/// `breakbulk-unit doctest`.
pub fn main() -> ExitCode {
    let outer = Outer::from_process();
    match read(&outer).and_then(|d| doctest(&d, &outer)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::directives::LibraryPath;
    use crate::spec::{CrateInfo, Platform, Splice, SpliceKind};

    fn out(paths: &[&str]) -> BuildOutput {
        BuildOutput {
            library_paths: paths
                .iter()
                .map(|p| LibraryPath {
                    value: (*p).to_owned(),
                    in_out_dir: false,
                    in_build_dir: false,
                })
                .collect(),
            ..BuildOutput::default()
        }
    }

    fn doctest(args: Vec<RenderedArg>, at: usize, runs: &[&str]) -> RenderedDoctest {
        RenderedDoctest {
            kind: DoctestKind::Doctest,
            compile: RenderedCompile {
                package: "path+file:///w/c#0.1.0".into(),
                krate: CrateInfo {
                    name: "c".into(),
                    types: vec!["lib".into()],
                    edition: "2021".into(),
                },
                platform: Platform::Target,
                program: vec!["/s/rustdoc".into()],
                args,
                env: BTreeMap::from([("CARGO_PKG_NAME".into(), "c".into())]),
                env_splices: vec![Splice::new("/f/a".into(), SpliceKind::RustcEnv)],
                dylib_path_from: vec![],
                cwd: "/src".into(),
                outputs: BTreeMap::new(),
                deps: vec![],
                dep_manifests: vec![],
                link_manifest_crates: false,
                manifest_crates: vec![],
                remap: vec![],
                remap_scope: None,
                env_capture: None,
                link_captures: Vec::new(),
                test_only: Vec::new(),
                seed: None,
            },
            search_paths_of: runs.iter().map(|s| (*s).to_owned()).collect(),
            search_paths_literals: vec![],
            search_paths_at: at,
        }
    }

    fn lit(s: &str) -> RenderedArg {
        RenderedArg::Literal(s.into())
    }

    #[test]
    fn search_paths_sort_by_component_and_dedup() {
        let d = BTreeMap::from([
            (
                "/f/a".to_owned(),
                out(&["native=/n/b-c", "/n/z", "native=/n/b/c"]),
            ),
            ("/f/b".to_owned(), out(&["native=/n/b-c", "/n/a"])),
        ]);
        let got = search_paths(&["/f/a".into(), "/f/b".into()], &[], |f| d.get(f)).unwrap();
        // Component order puts `b` before `b-c`; byte order would not.
        assert_eq!(got, ["/n/a", "/n/z", "native=/n/b/c", "native=/n/b-c"]);
        // A `links` override's paths sort into the same list.
        let got = search_paths(
            &["/f/b".into()],
            &["/n/m".into(), "native=/n/a".into(), "/n/a".into()],
            |f| d.get(f),
        )
        .unwrap();
        assert_eq!(got, ["/n/a", "/n/m", "native=/n/a", "native=/n/b-c"]);
    }

    #[test]
    fn invocation_places_runner_search_paths_and_test_args() {
        let mut a = out(&["native=/o/a/lib"]);
        a.env = vec![("FROM_SCRIPT".into(), "1".into())];
        a.cfgs = vec!["has_a".into()];
        let dirs = BTreeMap::from([("/f/a".to_owned(), a), ("/f/b".to_owned(), out(&["/x"]))]);
        let d = doctest(
            vec![
                lit("--test"),
                lit("src/lib.rs"),
                lit("--target"),
                lit("x86_64-unknown-linux-gnu"),
                lit("--extern"),
                lit("c=/s/libc.rlib"),
                RenderedArg::Splice(Splice::new("/f/a".into(), SpliceKind::RustcCfg)),
            ],
            4,
            &["/f/a", "/f/b"],
        );
        let config = TestConfig {
            runner: vec!["wine".into(), "--quiet".into()],
            args: vec!["--skip".into(), "net".into()],
            env: BTreeMap::from([
                ("PATH".into(), "/tools/bin".into()),
                ("EXTRA".into(), "yes".into()),
            ]),
            post_run: None,
        };
        let outer = Outer {
            vars: BTreeMap::from([("NIX_BUILD_CORES".into(), "3".into())]),
        };
        let inv = invocation(&d, &outer, &dirs, &config, Path::new("/t/deps")).unwrap();
        assert_eq!(
            inv.argv,
            [
                "/s/rustdoc",
                "--test",
                "src/lib.rs",
                "--target",
                "x86_64-unknown-linux-gnu",
                "--test-runtool",
                "wine",
                "--test-runtool-arg",
                "--quiet",
                "-L",
                "/x",
                "-L",
                "native=/o/a/lib",
                "--test-args",
                "--skip",
                "--test-args",
                "net",
                "--extern",
                "c=/s/libc.rlib",
                "--cfg",
                "has_a",
                "-L",
                "dependency=/t/deps",
            ]
        );
        assert_eq!(inv.env["FROM_SCRIPT"], "1");
        assert_eq!(inv.env["CARGO_PKG_NAME"], "c");
        assert_eq!(inv.env["EXTRA"], "yes");
        assert_eq!(inv.env["PATH"], "/tools/bin");
        assert_eq!(inv.env["RUST_TEST_THREADS"], "3");
        assert_eq!(inv.cwd, Path::new("/src"));
    }

    #[test]
    fn no_runner_no_args() {
        let d = doctest(vec![lit("--test"), lit("src/lib.rs")], 2, &[]);
        let inv = invocation(
            &d,
            &Outer::default(),
            &BTreeMap::from([("/f/a".to_owned(), out(&[]))]),
            &TestConfig::default(),
            Path::new("/d"),
        )
        .unwrap();
        assert_eq!(
            inv.argv,
            ["/s/rustdoc", "--test", "src/lib.rs", "-L", "dependency=/d"]
        );
    }

    #[test]
    fn rejects_bad_position_and_config() {
        let d = doctest(vec![lit("--test")], 2, &[]);
        let dirs = BTreeMap::from([("/f/a".to_owned(), out(&[]))]);
        let e = invocation(
            &d,
            &Outer::default(),
            &dirs,
            &TestConfig::default(),
            Path::new("/d"),
        )
        .unwrap_err();
        assert!(e.0.contains("past the end"), "{e}");
        let outer = Outer {
            vars: BTreeMap::from([(TEST_ARGS_VAR.into(), "{\"a\": 1}".into())]),
        };
        let e = TestConfig::from_outer(&outer).unwrap_err();
        assert!(e.0.starts_with(TEST_ARGS_VAR), "{e}");
    }

    #[test]
    fn parses_with_kind() {
        let d = doctest(vec![lit("--test")], 1, &["/f/a"]);
        let json = serde_json::to_string(&d).unwrap();
        assert!(json.starts_with("{\"kind\":\"doctest\""), "{json}");
        assert_eq!(serde_json::from_str::<RenderedDoctest>(&json).unwrap(), d);
    }
}
