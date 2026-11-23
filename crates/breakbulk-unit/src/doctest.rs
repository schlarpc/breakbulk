//! The `doctest` kind: run one library's doctests.
//!
//! The doctest derivation of a library runs the test plan's traced
//! `rustdoc --test` command ("Tests" in
//! `docs/src/explanation/internals/products.md`). rustdoc
//! compiles every example against the crate's `rlib` and its dependencies,
//! then runs it, in one process; so there is no output but the log, and no
//! cutoff.
//!
//! The command is a compile unit's ([`RenderedCompile`], with no outputs and
//! no remapping). Its `-L` list of every build-script run's search paths,
//! which Cargo computes from values rather than positions (`run_doc_tests`
//! in Cargo's `src/cargo/ops/cargo_test.rs`), is a `searchPathsOf` splice
//! ([`crate::splice::search_paths`]) at the position the trace showed.
//!
//! Configuration from the derivation's environment, all optional:
//!
//! - [`RUNNERS_VAR`]: a JSON object, the runner (a program and its
//!   arguments) of each platform, `host` and `target`. The doctest uses its
//!   own platform's, as Cargo picks the runner by the unit's compile kind
//!   (`Compilation::target_runner`): a proc macro's doctest is built and
//!   run for the host. Passed as Cargo does, `--test-runtool R
//!   --test-runtool-arg A …` right after `--test-run-directory D` and, for
//!   the target, `--target T`.
//! - [`TEST_ARGS_VAR`]: a JSON array of libtest arguments, each passed as
//!   `--test-args A` right after the `-L` list, where Cargo puts them.
//! - [`TEST_ENV_VAR`]: a JSON array of env layers merged over the command's
//!   environment, lowest first ([`crate::env::LayerValue`]: `{ "value": V,
//!   "sep": "" }` replaces, `{ "value": V, "sep": S }` appends): the
//!   package's `test.env`, then its `test.path` on `PATH`.
//!
//! - [`POST_RUN_VAR`]: a program run after passing doctests (the
//!   package's `test.postRun` snippets, `test.keepLog`'s copy), in
//!   `$TMPDIR`, with `log` and `out` set.
//!
//! The doctests get a fresh, empty `HOME` in `$TMPDIR`
//! ([`Outer::test_base`]), and `RUST_TEST_THREADS` is set to the job count
//! ([`Outer::jobs`]); the test env overrides either. The combined stdout and stderr go to the build log and
//! to [`LOG_FILE`] in `$TMPDIR`, not `$out`: the output holds timings and
//! lines in a varying order, and `nix build --rebuild` compares `$out`,
//! which stays empty unless the post-run program fills it. The derivation
//! fails when rustdoc exits non-zero, with a hint for each path the log
//! names that the source view lacks ([`crate::view_hints`]).

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;

use crate::compile::{Invocation, check_args, fresh_dir, link_deps, load_directives};
use crate::directives::BuildOutput;
use crate::env::{
    CFlags, EnvAppend, EnvLayer, Outer, capture_layer, fold_layers, layered_on, merge_rendered,
};
use crate::process::{command, describe_status, shell_words};
use crate::spec::{Platform, RenderedArg, RenderedCompile};
use crate::splice::{check_arg_splices, expand_args, expand_env, prepend_dylib_path};
use crate::{Error, io_err, view_hints};

pub const RUNNERS_VAR: &str = "BREAKBULK_TEST_RUNNERS";
pub const TEST_ARGS_VAR: &str = "BREAKBULK_TEST_ARGS";
pub const TEST_ENV_VAR: &str = "BREAKBULK_TEST_ENV";

pub const POST_RUN_VAR: &str = "BREAKBULK_TEST_POST_RUN";

/// The log file in `$TMPDIR`.
pub const LOG_FILE: &str = "breakbulk-doctest.log";

/// The configuration a doctest derivation adds to the traced command.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TestConfig {
    /// Each platform's runner; a platform without one runs directly.
    pub runners: BTreeMap<Platform, Vec<String>>,
    pub args: Vec<String>,
    /// Lowest first.
    pub env: Vec<EnvLayer>,
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
            runners: parse(outer, RUNNERS_VAR)?,
            args: parse(outer, TEST_ARGS_VAR)?,
            env: parse(outer, TEST_ENV_VAR)?,
            post_run: outer
                .get(POST_RUN_VAR)
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
        })
    }
}

/// The full command: the traced arguments with the doctest's platform's
/// runner where Cargo puts it, the test arguments right after the
/// `searchPathsOf` splice (or at the end without one), and the dependency
/// directory last.
pub fn invocation(
    c: &RenderedCompile,
    outer: &Outer,
    directives: &BTreeMap<String, BuildOutput>,
    config: &TestConfig,
    deps_dir: &Path,
) -> Result<Invocation, Error> {
    check_args(c)?;
    if c.program.is_empty() {
        return Err(Error::new("the doctest has an empty program"));
    }
    let splices: Vec<_> = c
        .args
        .iter()
        .enumerate()
        .filter_map(|(i, a)| match a {
            RenderedArg::Splice(s) => Some((i, s)),
            _ => None,
        })
        .collect();
    check_arg_splices(&splices)?;
    let lookup = |f: &str| directives.get(f);
    let at = c
        .args
        .iter()
        .position(|a| matches!(a, RenderedArg::SearchPaths(_)))
        .unwrap_or(c.args.len());
    let (before, after) = c.args.split_at(at);
    let (search, after) = after.split_at(after.len().min(1));
    let mut before = expand_args(before, lookup)?;
    let search = expand_args(search, lookup)?;
    let after = expand_args(after, lookup)?;

    let runner = config
        .runners
        .get(&c.platform)
        .map_or(&[][..], Vec::as_slice);
    if let Some((tool, args)) = runner.split_first() {
        let mut runtool = vec!["--test-runtool".to_owned(), tool.clone()];
        for a in args {
            runtool.extend(["--test-runtool-arg".to_owned(), a.clone()]);
        }
        // Cargo: `--test-run-directory D`, then `--target T` for a target
        // unit (`add_target_arg`), then the runner.
        let after = |flag: &str| {
            before
                .iter()
                .position(|a| a == flag)
                .map(|i| (i + 2).min(before.len()))
        };
        let at = after("--target")
            .or_else(|| after("--test-run-directory"))
            .unwrap_or(before.len());
        before.splice(at..at, runtool);
    }

    let mut argv = c.program.clone();
    argv.extend(before);
    argv.extend(search);
    for a in &config.args {
        argv.extend(["--test-args".to_owned(), a.clone()]);
    }
    argv.extend(after);
    argv.extend([
        "-L".to_owned(),
        format!("dependency={}", deps_dir.display()),
    ]);

    let (layer_env, env_append) = c.layered_env();

    let mut unit_env = expand_env(&layer_env, &c.env_splices, lookup)?;
    prepend_dylib_path(&mut unit_env, &c.dylib_path_from, lookup)?;
    let capture = capture_layer(c.env_capture.as_deref(), &c.link_captures)?;
    let mut env = layered_on(
        outer.test_base(),
        outer,
        capture.as_ref(),
        &unit_env,
        &env_append,
        &CFlags::default(),
    );
    env.insert("RUST_TEST_THREADS".into(), outer.jobs().to_string());
    let (values, appends) = fold_layers(&BTreeMap::new(), &EnvAppend::new(), &config.env);
    merge_rendered(&mut env, &values, &appends);
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

/// The whole `doctest` kind.
pub fn doctest(c: &RenderedCompile, outer: &Outer) -> Result<(), Error> {
    let config = TestConfig::from_outer(outer)?;
    let deps = outer.tmpdir().join("deps");
    let directives = load_directives(c)?;
    let inv = invocation(c, outer, &directives, &config, &deps)?;
    link_deps(&c.deps, &[], &deps)?;
    let home = outer.test_home();
    std::fs::create_dir_all(&home).map_err(|e| io_err("creating", &home, e))?;
    let out = outer.output("out")?;
    fresh_dir(&out)?;
    let log = outer.tmpdir().join(LOG_FILE);
    let status = run_logged(&inv, &log)?;
    if !status.success() {
        let mut msg = format!(
            "doctests of `{}` failed ({})",
            c.krate.name,
            describe_status(&status)
        );
        let text = String::from_utf8_lossy(&std::fs::read(&log).unwrap_or_default()).into_owned();
        for h in view_hints::hints(&c.package, &text, c.hints.view.as_ref(), &c.remap, &inv.cwd) {
            msg.push_str("\nhint: ");
            msg.push_str(&h);
        }
        return Err(Error(msg));
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::directives::LibraryPath;
    use crate::spec::{CrateInfo, RenderedUnit, SearchPaths, Splice, SpliceKind};
    use crate::splice::search_paths;

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

    /// A doctest whose `searchPathsOf` splice of `runs` is at `at`.
    fn doctest(mut args: Vec<RenderedArg>, at: usize, runs: &[&str]) -> RenderedCompile {
        args.insert(
            at,
            RenderedArg::SearchPaths(SearchPaths {
                search_paths_of: runs.iter().map(|s| (*s).to_owned()).collect(),
                literals: vec![],
            }),
        );
        {
            RenderedCompile {
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
                env_append: Default::default(),
                env_layers: Vec::new(),
                env_splices: vec![Splice::new("/f/a".into(), SpliceKind::RustcEnv)],
                dylib_path_from: vec![],
                cwd: "/src".into(),
                outputs: Vec::new(),
                deps: vec![],
                dep_manifests: vec![],
                link_manifest_crates: false,
                manifest_crates: vec![],
                remap: vec![],
                remap_scope: None,
                env_capture: None,
                link_captures: Vec::new(),
                hints: Default::default(),
                seed: None,
            }
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
        let sp = |runs: &[&str], literals: &[&str]| SearchPaths {
            search_paths_of: runs.iter().map(|s| (*s).to_owned()).collect(),
            literals: literals.iter().map(|s| (*s).to_owned()).collect(),
        };
        let got = search_paths(&sp(&["/f/a", "/f/b"], &[]), |f| d.get(f)).unwrap();
        // Component order puts `b` before `b-c`; byte order would not.
        assert_eq!(got, ["/n/a", "/n/z", "native=/n/b/c", "native=/n/b-c"]);
        // A `links` override's paths sort into the same list.
        let got = search_paths(&sp(&["/f/b"], &["/n/m", "native=/n/a", "/n/a"]), |f| {
            d.get(f)
        })
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
            runners: BTreeMap::from([
                (Platform::Target, vec!["wine".into(), "--quiet".into()]),
                (Platform::Host, vec!["/host/runner".into()]),
            ]),
            args: vec!["--skip".into(), "net".into()],
            env: vec![BTreeMap::from([
                (
                    "PATH".into(),
                    crate::env::LayerValue::append("/tools/bin", ':'),
                ),
                ("EXTRA".into(), crate::env::LayerValue::set("yes")),
            ])],
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
    fn a_host_doctest_gets_the_hosts_runner_after_the_run_directory() {
        let mut d = doctest(
            vec![
                lit("--test"),
                lit("src/lib.rs"),
                lit("--test-run-directory"),
                lit("/src"),
                lit("--extern"),
                lit("c=/s/libc.so"),
            ],
            4,
            &[],
        );
        d.platform = Platform::Host;
        let dirs = BTreeMap::from([("/f/a".to_owned(), out(&[]))]);
        let target_only = TestConfig {
            runners: BTreeMap::from([(Platform::Target, vec!["qemu-aarch64".into()])]),
            ..TestConfig::default()
        };
        let inv = invocation(&d, &Outer::default(), &dirs, &target_only, Path::new("/d")).unwrap();
        assert!(
            !inv.argv.iter().any(|a| a.starts_with("--test-runtool")),
            "{:?}",
            inv.argv
        );
        let both = TestConfig {
            runners: BTreeMap::from([
                (Platform::Target, vec!["qemu-aarch64".into()]),
                (Platform::Host, vec!["/host/runner".into(), "-v".into()]),
            ]),
            ..TestConfig::default()
        };
        let inv = invocation(&d, &Outer::default(), &dirs, &both, Path::new("/d")).unwrap();
        assert_eq!(
            inv.argv,
            [
                "/s/rustdoc",
                "--test",
                "src/lib.rs",
                "--test-run-directory",
                "/src",
                "--test-runtool",
                "/host/runner",
                "--test-runtool-arg",
                "-v",
                "--extern",
                "c=/s/libc.so",
                "-L",
                "dependency=/d",
            ]
        );
        let outer = Outer {
            vars: BTreeMap::from([(
                RUNNERS_VAR.into(),
                r#"{"host": ["/h"], "target": ["/t", "-x"]}"#.into(),
            )]),
        };
        assert_eq!(
            TestConfig::from_outer(&outer).unwrap().runners,
            BTreeMap::from([
                (Platform::Host, vec!["/h".to_owned()]),
                (Platform::Target, vec!["/t".to_owned(), "-x".to_owned()]),
            ])
        );
    }

    #[test]
    fn home_is_fresh_unless_the_test_env_sets_it() {
        let d = doctest(vec![lit("--test")], 1, &[]);
        let dirs = BTreeMap::from([("/f/a".to_owned(), out(&[]))]);
        let outer = Outer {
            vars: BTreeMap::from([
                ("TMPDIR".into(), "/build".into()),
                ("HOME".into(), "/homeless-shelter".into()),
            ]),
        };
        let inv = invocation(&d, &outer, &dirs, &TestConfig::default(), Path::new("/d")).unwrap();
        assert_eq!(inv.env["HOME"], "/build/home");
        let config = TestConfig {
            env: vec![BTreeMap::from([(
                "HOME".into(),
                crate::env::LayerValue::set("/homeless-shelter"),
            )])],
            ..TestConfig::default()
        };
        let inv = invocation(&d, &outer, &dirs, &config, Path::new("/d")).unwrap();
        assert_eq!(inv.env["HOME"], "/homeless-shelter");
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
    fn rejects_bad_config() {
        let outer = Outer {
            vars: BTreeMap::from([(TEST_ARGS_VAR.into(), "{\"a\": 1}".into())]),
        };
        let e = TestConfig::from_outer(&outer).unwrap_err();
        assert!(e.0.starts_with(TEST_ARGS_VAR), "{e}");
    }

    #[test]
    fn parses_with_kind() {
        let d = RenderedUnit::Doctest(doctest(vec![lit("--test")], 1, &["/f/a"]));
        let json = serde_json::to_string(&d).unwrap();
        assert!(json.starts_with("{\"kind\":\"doctest\""), "{json}");
        assert!(json.contains("{\"searchPathsOf\":[\"/f/a\"]}"), "{json}");
        assert_eq!(serde_json::from_str::<RenderedUnit>(&json).unwrap(), d);
    }
}
