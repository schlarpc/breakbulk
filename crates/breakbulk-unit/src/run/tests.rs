use std::collections::BTreeMap;
use std::os::unix::process::ExitStatusExt;
use std::process::ExitStatus;

use super::*;
use crate::spec::{PackageTarget, Platform};
use crate::test_util::TempDir;

const PKG: &str = "registry+https://github.com/rust-lang/crates.io-index#foo-sys@1.2.3";

fn unit(cwd: &Path) -> RenderedRun {
    RenderedRun {
        package: PKG.into(),
        platform: Platform::Target,
        links: Some("foo".into()),
        script: "/nix/store/c-build/build_script_build-1".into(),
        env: BTreeMap::from([("TARGET".into(), "x86_64-unknown-linux-gnu".into())]),
        out_dir: String::new(),
        cwd: cwd.display().to_string(),
        metadata_from: vec![],
        dylib_path_from: vec![],
        rust_version: None,
        targets: vec![PackageTarget {
            name: "foo_sys".into(),
            kind: vec!["lib".into()],
        }],
        nightly_features_allowed: false,
        env_capture: None,
        seed: None,
        remap: vec![],
        out_dir_remap: None,
        strict_sources: false,
    }
}

fn judge_with(r: &RenderedRun, status: i32, stdout: &str) -> Result<Success, Error> {
    judge_with_stderr(r, status, stdout, "")
}

fn judge_with_stderr(
    r: &RenderedRun,
    status: i32,
    stdout: &str,
    stderr: &str,
) -> Result<Success, Error> {
    let env = BTreeMap::from([("SET".to_owned(), "1".to_owned())]);
    judge(&Finished {
        run: r,
        argv: &["/s/build-script-build".into()],
        env: &env,
        out: Path::new("/o"),
        upstream_out_dirs: &[],
        status: ExitStatus::from_raw(status),
        stdout: stdout.as_bytes(),
        stderr_tail: stderr.as_bytes(),
    })
}

#[test]
fn success_parses_directives() {
    let t = TempDir::new("ok");
    std::fs::write(t.path().join("build.rs"), "").unwrap();
    let r = unit(t.path());
    let s = judge_with(
        &r,
        0,
        "noise\ncargo::rustc-cfg=a\ncargo::warning=careful\ncargo::rerun-if-changed=build.rs\ncargo::metadata=include=/o/inc\n",
    )
    .unwrap();
    assert_eq!(s.output.cfgs, ["a"]);
    assert_eq!(s.output.metadata, [("include".into(), "/o/inc".into())]);
    assert_eq!(s.warnings, ["warning: foo-sys@1.2.3: careful"]);
}

#[test]
fn non_zero_exit_fails_with_stdout_and_hints() {
    let t = TempDir::new("exit");
    let r = unit(t.path());
    let e = judge_with(
        &r,
        1 << 8,
        "cargo::rerun-if-changed=vendor/foo.c\ncargo::rerun-if-env-changed=FOO_DIR\ncargo::rerun-if-env-changed=SET\n",
    )
    .unwrap_err();
    assert!(
        e.0.starts_with("failed to run custom build command for `foo-sys v1.2.3`"),
        "{e}"
    );
    assert!(
        e.0.contains("process didn't exit successfully: `/s/build-script-build` (exit status: 1)"),
        "{e}"
    );
    assert!(
        e.0.contains("--- stdout\n  cargo::rerun-if-changed=vendor/foo.c"),
        "{e}"
    );
    assert!(
        e.0.contains("add it to `packages.foo-sys.extraSources`"),
        "{e}"
    );
    assert!(e.0.contains("reads `FOO_DIR`"), "{e}");
    assert!(e.0.contains("`packages.foo-sys.env.FOO_DIR`"), "{e}");
    assert!(!e.0.contains("reads `SET`"), "{e}");
}

#[test]
fn failure_ends_with_stderr_and_deduplicates_hints() {
    let t = TempDir::new("tail");
    let r = unit(t.path());
    let stderr: String = (0..30)
        .map(|i| format!("cmake line {i}\n"))
        .collect::<String>()
        + "thread 'main' panicked at build.rs:440:13:\nFailed to copy\n";
    let e = judge_with_stderr(
        &r,
        101 << 8,
        "cargo::rerun-if-env-changed=FOO_DIR\ncargo::rerun-if-env-changed=FOO_DIR\n\
         cargo::rerun-if-changed=vendor/foo.c\ncargo::rerun-if-changed=vendor/foo.c\n",
        &stderr,
    )
    .unwrap_err();
    assert_eq!(e.0.matches("reads `FOO_DIR`").count(), 1, "{e}");
    assert_eq!(
        e.0.matches("rerun-if-changed=vendor/foo.c`, but").count(),
        1,
        "{e}"
    );
    let tail =
        e.0.split("--- stderr (last 20 lines; all of it is above)\n")
            .nth(1)
            .expect("a stderr section");
    assert!(tail.trim_end().ends_with("Failed to copy"), "{e}");
    assert!(tail.contains("panicked at build.rs:440:13"), "{e}");
    assert!(!tail.contains("cmake line 11\n"), "{e}");
    assert!(tail.contains("cmake line 12\n"), "{e}");
    // Hints come before the stderr section.
    assert!(
        e.0.find("hint:").unwrap() < e.0.find("--- stderr").unwrap(),
        "{e}"
    );
}

#[test]
fn death_by_signal_names_the_signal() {
    let t = TempDir::new("sig");
    let e = judge_with(&unit(t.path()), 11, "").unwrap_err();
    assert!(e.0.contains("(signal: 11, SIGSEGV)"), "{e}");
    let e = judge_with(&unit(t.path()), 9, "").unwrap_err();
    assert!(e.0.contains("(signal: 9, SIGKILL)"), "{e}");
}

#[test]
fn error_directives_follow_cargo() {
    let t = TempDir::new("err");
    let r = unit(t.path());
    let e = judge_with(&r, 0, "cargo::error=no compiler\n").unwrap_err();
    assert!(e.0.contains("build script logged errors"), "{e}");
    // Leading whitespace: printed, but Cargo does not fail the run
    // (decision log #8).
    let s = judge_with(&r, 0, "  cargo::error=soft\n").unwrap();
    assert_eq!(s.warnings, ["error: foo-sys@1.2.3: soft"]);
    // A directive Cargo rejects fails the run.
    let e = judge_with(&r, 0, "cargo::rustc-link-arg-bins=x\n").unwrap_err();
    assert!(e.0.contains("does not have a bin target"), "{e}");
    let e = judge_with(&r, 0, "cargo::bogus=x\n").unwrap_err();
    assert!(e.0.contains("Unknown key: `bogus`"), "{e}");
}

#[test]
fn missing_sources_warn_or_fail() {
    let t = TempDir::new("strict");
    let mut r = unit(t.path());
    let s = judge_with(
        &r,
        0,
        "cargo::rerun-if-changed=../shared/x.h\ncargo::rerun-if-changed=/usr/include/z.h\n",
    )
    .unwrap();
    assert_eq!(s.warnings.len(), 2, "{:?}", s.warnings);
    assert!(
        s.warnings[0].contains("packages.foo-sys.extraSources"),
        "{:?}",
        s.warnings
    );
    assert!(
        s.warnings[1].contains("packages.foo-sys.inputs"),
        "{:?}",
        s.warnings
    );
    r.strict_sources = true;
    let e = judge_with(&r, 0, "cargo::rerun-if-changed=../shared/x.h\n").unwrap_err();
    assert!(e.0.contains("`strictSources` is set"), "{e}");
    // Present paths, and paths in OUT_DIR the script created, are fine.
    std::fs::write(t.path().join("present"), "").unwrap();
    judge_with(&r, 0, "cargo::rerun-if-changed=present\n").unwrap();
}

#[test]
fn dep_env_and_out_dir() {
    let r = unit(Path::new("/src"));
    let mut r2 = r.clone();
    r2.env.insert("OUT_DIR".into(), "/stale".into());
    let md = [
        MetadataFile {
            links: "z".into(),
            metadata: vec![("include".into(), "/z/inc".into())],
            out: None,
        },
        MetadataFile {
            links: "open-ssl".into(),
            metadata: vec![("version-number".into(), "30".into())],
            out: None,
        },
    ];
    let env = run_env(&r2, Path::new("/nix/store/o-out"), &md);
    assert_eq!(env["OUT_DIR"], "/nix/store/o-out");
    assert_eq!(env["DEP_Z_INCLUDE"], "/z/inc");
    assert_eq!(env["DEP_OPEN_SSL_VERSION_NUMBER"], "30");
    assert_eq!(env["TARGET"], "x86_64-unknown-linux-gnu");
}

#[test]
fn script_in_a_directory() {
    let t = TempDir::new("script");
    let f = t.path().join("build_script_build-1");
    std::fs::write(&f, "").unwrap();
    assert_eq!(script_path(t.path()).unwrap(), f);
    assert_eq!(script_path(&f).unwrap(), f);
    std::fs::write(t.path().join("other"), "").unwrap();
    assert!(script_path(t.path()).is_err());
}

/// A shell script as the build script, run end to end.
#[test]
fn run_mode_end_to_end() {
    use std::os::unix::fs::PermissionsExt;
    let t = TempDir::new("e2e");
    let src = t.path().join("src");
    std::fs::create_dir_all(&src).unwrap();
    std::fs::write(src.join("marker"), "").unwrap();
    let script = t.path().join("build-script-build");
    std::fs::write(
        &script,
        "#!/bin/sh\n\
         test -f marker || exit 9\n\
         echo hi > \"$OUT_DIR/gen\"\n\
         echo \"cargo::rustc-link-search=native=$OUT_DIR\"\n\
         echo \"cargo::rustc-link-search=native=/elsewhere\"\n\
         echo \"cargo::metadata=root=$OUT_DIR\"\n\
         echo \"cargo::rustc-env=JOBS=$NUM_JOBS:$DEP_UP_KEY:$HOME:${PATH:-}\"\n",
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let up = t.path().join("up-flags");
    std::fs::create_dir_all(&up).unwrap();
    crate::write_json(
        &up.join(METADATA_FILE),
        &MetadataFile {
            links: "up".into(),
            metadata: vec![("key".into(), "v".into())],
            out: Some("/up-out".into()),
        },
    )
    .unwrap();
    let mut r = unit(&src);
    r.script = script.display().to_string();
    r.metadata_from = vec![up.display().to_string()];
    r.env.insert("NUM_JOBS".into(), "99".into());
    let out = t.path().join("out");
    let flags = t.path().join("flags");
    let outer = Outer {
        vars: BTreeMap::from([
            ("out".into(), out.display().to_string()),
            ("flags".into(), flags.display().to_string()),
            ("NIX_BUILD_CORES".into(), "3".into()),
            ("TMPDIR".into(), t.path().display().to_string()),
            ("PATH".into(), "/leak".into()),
        ]),
    };
    run(&r, &outer).unwrap();
    assert_eq!(std::fs::read_to_string(out.join("gen")).unwrap(), "hi\n");
    let d = crate::read_directives(&flags).unwrap();
    // The shell may substitute its own default PATH, but never the outer one.
    assert_eq!(d.env[0].0, "JOBS");
    assert!(
        d.env[0].1.starts_with("3:v:/homeless-shelter:"),
        "{:?}",
        d.env
    );
    assert!(!d.env[0].1.contains("/leak"), "{:?}", d.env);
    assert!(d.library_paths[0].in_out_dir);
    assert!(!d.library_paths[1].in_out_dir);
    let m = crate::read_metadata(&flags).unwrap();
    assert_eq!(m.links, "foo");
    assert_eq!(m.metadata, [("root".into(), out.display().to_string())]);

    // The script's exit status is reported.
    std::fs::write(&script, "#!/bin/sh\nkill -ABRT $$\n").unwrap();
    let e = run(&r, &outer).unwrap_err();
    assert!(e.0.contains("signal: 6, SIGABRT"), "{e}");
}

#[test]
fn cmake_state_is_removed_from_build_trees_only() {
    let t = TempDir::new("cmake");
    let out = t.path();
    let mk = |rel: &str, body: &str| {
        let p = out.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, body).unwrap();
    };
    // The cmake crate's tree, with the installed library beside it.
    mk("build/CMakeCache.txt", "cache");
    mk(
        "build/CMakeFiles/CMakeConfigureLog.yaml",
        "TryCompile-abcdef",
    );
    mk(
        "build/CMakeFiles/CMakeScratch/TryCompile-abcdef/CMakeCache.txt",
        "",
    );
    mk("build/CMakeFiles/cm.dir/cm.c.o", "obj");
    mk("build/libcm.a", "lib");
    mk("build/sub/CMakeFiles/sub.dir/s.c.o", "obj");
    mk("lib/libcm.a", "lib");
    // A `CMakeFiles` that is not next to a cache is left alone.
    mk("other/CMakeFiles/keep", "");
    let removed = remove_cmake_state(out).unwrap();
    assert_eq!(removed, [out.join("build/CMakeFiles")]);
    assert!(!out.join("build/CMakeFiles").exists());
    for kept in [
        "build/CMakeCache.txt",
        "build/libcm.a",
        "build/sub/CMakeFiles/sub.dir/s.c.o",
        "lib/libcm.a",
        "other/CMakeFiles/keep",
    ] {
        assert!(out.join(kept).exists(), "{kept} was removed");
    }
    assert_eq!(remove_cmake_state(out).unwrap(), Vec::<PathBuf>::new());
}

#[test]
fn out_dir_inside_a_copy_of_cargos_layout() {
    let t = TempDir::new("layout");
    let out = t.path().join("out");
    // Classic layout: Cargo creates `deps` and `examples` beside `build`.
    let d = prepare_out_dir(
        &out,
        "x86_64-unknown-linux-gnu/debug/build/sdl2-sys-1a2b/out",
    )
    .unwrap();
    assert_eq!(
        d,
        out.join("x86_64-unknown-linux-gnu/debug/build/sdl2-sys-1a2b/out")
    );
    assert!(out.join("x86_64-unknown-linux-gnu/debug/deps").is_dir());
    assert!(out.join("x86_64-unknown-linux-gnu/debug/examples").is_dir());
    // The new layout creates neither.
    let out2 = t.path().join("out2");
    prepare_out_dir(&out2, "debug/build/build/1a2b/out").unwrap();
    assert!(out2.join("debug/build/build/1a2b/out").is_dir());
    assert!(!out2.join("debug/deps").exists());
    assert!(!out2.join("debug/build/deps").exists());
    // No relative path: the `out` itself.
    assert_eq!(prepare_out_dir(&out2, "").unwrap(), out2);

    std::fs::write(d.join("inside.txt"), "").unwrap();
    std::fs::write(out.join("x86_64-unknown-linux-gnu/debug/libSDL2.so"), "").unwrap();
    std::os::unix::fs::symlink(
        "/x",
        out.join("x86_64-unknown-linux-gnu/debug/deps/libSDL2.so"),
    )
    .unwrap();
    assert_eq!(
        files_outside(&out, &d).unwrap(),
        [
            "x86_64-unknown-linux-gnu/debug/deps/libSDL2.so",
            "x86_64-unknown-linux-gnu/debug/libSDL2.so"
        ]
    );
    assert!(files_outside(&d, &d).unwrap().is_empty());
}
