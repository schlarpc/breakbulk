use std::collections::BTreeMap;

use super::*;
use crate::directives::LibraryPath;
use crate::spec::{CrateInfo, Platform, Splice, SpliceKind};
use crate::test_util::TempDir;

fn unit(args: &[&str]) -> RenderedCompile {
    RenderedCompile {
        package: "path+file:///w/app#0.1.0".into(),
        krate: CrateInfo {
            name: "app".into(),
            types: vec!["bin".into()],
            edition: "2024".into(),
        },
        platform: Platform::Target,
        program: vec!["/nix/store/x-rustc/bin/rustc".into()],
        args: args
            .iter()
            .map(|a| RenderedArg::Literal(a.to_string()))
            .collect(),
        env: BTreeMap::new(),
        env_splices: vec![],
        cwd: "/nix/store/x-src".into(),
        outputs: BTreeMap::from([("bin".into(), vec!["app-1".into()])]),
        deps: vec![],
        remap: vec![],
        remap_scope: None,
        env_capture: None,
    }
}

#[test]
fn rejects_target_directory_arguments() {
    for args in [
        &["--out-dir", "/x"][..],
        &["--out-dir=/x"],
        &["-C", "incremental=/x"],
        &["-Cincremental=/x"],
        &["--codegen", "incremental=/x"],
        &["--codegen=incremental=/x"],
        &["-L", "dependency=/x"],
        &["-Ldependency=/x"],
    ] {
        let e = check_args(&unit(args)).unwrap_err();
        assert!(
            e.0.contains("must leave it to breakbulk-unit"),
            "{args:?}: {e}"
        );
    }
    for args in [
        &["-L", "native=/x"][..],
        &["-C", "opt-level=3"],
        &["--remap-path-prefix=/a=b"],
        &["--remap-path-scope=all"],
        &["-C", "link-arg=-Wl,--out-dir"],
    ] {
        check_args(&unit(args)).unwrap();
    }
    let mut u = unit(&["--remap-path-scope=all"]);
    u.remap = vec![("/a".into(), "b".into())];
    u.remap_scope = Some("macro".into());
    assert!(check_args(&u).is_err());
}

#[test]
fn appended_arguments() {
    let dirs = WorkDirs::under(Path::new("/build"));
    let mut u = unit(&[]);
    assert_eq!(
        added_args(&u, &dirs),
        ["--out-dir", "/build/out", "-L", "dependency=/build/deps"]
    );
    u.remap = vec![
        ("/nix/store/a-src".into(), "smokelib-0.1.0".into()),
        ("/nix/store/b-out".into(), "/out".into()),
    ];
    u.remap_scope = Some("macro,diagnostics".into());
    assert_eq!(
        &added_args(&u, &dirs)[4..],
        [
            "--remap-path-prefix=/nix/store/a-src=smokelib-0.1.0",
            "--remap-path-prefix=/nix/store/b-out=/out",
            "--remap-path-scope=macro,diagnostics"
        ]
    );
    // No scope flag without remaps.
    u.remap.clear();
    assert_eq!(added_args(&u, &dirs).len(), 4);
}

#[test]
fn invocation_expands_splices_and_env() {
    let mut u = unit(&["--crate-name", "app"]);
    let flags = "/nix/store/r-flags".to_owned();
    u.args.push(RenderedArg::Splice(Splice {
        splice: flags.clone(),
        kind: SpliceKind::RustcCfg,
        bin: None,
    }));
    u.args.push(RenderedArg::Splice(Splice {
        splice: flags.clone(),
        kind: SpliceKind::RustcLinkSearch,
        bin: None,
    }));
    u.env_splices.push(Splice {
        splice: flags.clone(),
        kind: SpliceKind::RustcEnv,
        bin: None,
    });
    u.env.insert("CARGO_PKG_NAME".into(), "app".into());
    u.env.insert("NUM_JOBS".into(), "64".into());
    let d = BuildOutput {
        cfgs: vec!["smoke".into()],
        library_paths: vec![LibraryPath {
            value: "native=/nix/store/r-out/native".into(),
            in_out_dir: true,
        }],
        env: vec![("SMOKE".into(), "1".into())],
        ..Default::default()
    };
    let directives = BTreeMap::from([(flags, d)]);
    let outer = crate::env::Outer {
        vars: BTreeMap::from([
            ("TMPDIR".into(), "/build".into()),
            ("NIX_BUILD_CORES".into(), "2".into()),
            ("PATH".into(), "/leak".into()),
        ]),
    };
    let inv = invocation(
        &u,
        &outer,
        &directives,
        &WorkDirs::under(Path::new("/build")),
    )
    .unwrap();
    assert_eq!(
        inv.argv,
        [
            "/nix/store/x-rustc/bin/rustc",
            "--crate-name",
            "app",
            "--cfg",
            "smoke",
            "-L",
            "native=/nix/store/r-out/native",
            "--out-dir",
            "/build/out",
            "-L",
            "dependency=/build/deps"
        ]
    );
    assert_eq!(inv.env["SMOKE"], "1");
    assert_eq!(inv.env["NUM_JOBS"], "2");
    assert_eq!(inv.env["HOME"], "/homeless-shelter");
    assert!(!inv.env.contains_key("PATH"));
    assert_eq!(inv.cwd, PathBuf::from("/nix/store/x-src"));

    // A splice whose run has no directives loaded is an error.
    assert!(
        invocation(
            &u,
            &outer,
            &BTreeMap::new(),
            &WorkDirs::under(Path::new("/b"))
        )
        .is_err()
    );
}

#[test]
fn directives_are_read_from_flags_dirs() {
    let t = TempDir::new("load");
    let flags = t.path().join("flags");
    std::fs::create_dir_all(&flags).unwrap();
    let d = BuildOutput {
        cfgs: vec!["x".into()],
        ..Default::default()
    };
    crate::write_json(&flags.join(crate::DIRECTIVES_FILE), &d).unwrap();
    let mut u = unit(&[]);
    u.env_splices.push(Splice {
        splice: flags.display().to_string(),
        kind: SpliceKind::RustcEnv,
        bin: None,
    });
    let loaded = load_directives(&u).unwrap();
    assert_eq!(loaded[&flags.display().to_string()], d);
    u.env_splices[0].splice = t.path().join("nope").display().to_string();
    assert!(load_directives(&u).unwrap_err().0.contains("nope"));
}

#[test]
fn deps_directory() {
    let t = TempDir::new("deps");
    let a = t.path().join("a");
    let b = t.path().join("b");
    std::fs::create_dir_all(&a).unwrap();
    std::fs::create_dir_all(&b).unwrap();
    std::fs::write(a.join("libx-1.rmeta"), "x").unwrap();
    std::fs::write(b.join("liby-1.rlib"), "y").unwrap();
    std::fs::write(b.join("libx-1.rmeta"), "other").unwrap();
    let deps = t.path().join("deps");
    let x = a.join("libx-1.rmeta").display().to_string();
    let y = b.join("liby-1.rlib").display().to_string();
    link_deps(&[x.clone(), y.clone(), x.clone()], &deps).unwrap();
    assert_eq!(
        std::fs::read_to_string(deps.join("libx-1.rmeta")).unwrap(),
        "x"
    );
    assert_eq!(
        std::fs::read_to_string(deps.join("liby-1.rlib")).unwrap(),
        "y"
    );
    // Recreated from scratch.
    link_deps(std::slice::from_ref(&y), &deps).unwrap();
    assert!(!deps.join("libx-1.rmeta").exists());
    // Same name, different files.
    let x2 = b.join("libx-1.rmeta").display().to_string();
    assert!(
        link_deps(&[x, x2], &deps)
            .unwrap_err()
            .0
            .contains("two dependencies")
    );
    let missing = t.path().join("gone.rlib").display().to_string();
    assert!(
        link_deps(&[missing], &deps)
            .unwrap_err()
            .0
            .contains("does not exist")
    );
}

#[test]
fn outputs_are_moved() {
    let t = TempDir::new("outputs");
    let from = t.path().join("out");
    std::fs::create_dir_all(&from).unwrap();
    for f in ["libx-1.rmeta", "libx-1.rlib", "x-1.d", "stray.o"] {
        std::fs::write(from.join(f), f).unwrap();
    }
    let outputs = BTreeMap::from([
        ("rmeta".to_owned(), vec!["libx-1.rmeta".to_owned()]),
        ("rlib".to_owned(), vec!["libx-1.rlib".to_owned()]),
    ]);
    let root = t.path().to_owned();
    let dest = |o: &str| Ok(root.join(format!("drv-{o}")));
    collect_outputs(&outputs, &from, dest).unwrap();
    assert_eq!(
        std::fs::read_to_string(t.path().join("drv-rmeta/libx-1.rmeta")).unwrap(),
        "libx-1.rmeta"
    );
    assert!(t.path().join("drv-rlib/libx-1.rlib").exists());
    assert!(!from.join("libx-1.rlib").exists());

    // `bin` goes to `out`; an output listing no file is still created.
    let outputs = BTreeMap::from([
        ("bin".to_owned(), vec!["stray.o".to_owned()]),
        ("rmeta".to_owned(), vec![]),
    ]);
    let root2 = t.path().join("second");
    let dest = |o: &str| Ok(root2.join(o));
    collect_outputs(&outputs, &from, dest).unwrap();
    assert!(t.path().join("second/out/stray.o").exists());
    assert!(t.path().join("second/rmeta").is_dir());

    let outputs = BTreeMap::from([("bin".to_owned(), vec!["app-1".to_owned()])]);
    let e = collect_outputs(&outputs, &from, |o| Ok(t.path().join(o))).unwrap_err();
    assert!(e.0.contains("did not write `app-1`"), "{e}");
    assert!(e.0.contains("x-1.d"), "{e}");
}

#[cfg(unix)]
#[test]
fn rustc_failure_names_the_crate() {
    let t = TempDir::new("fail");
    let inv = Invocation {
        argv: vec![
            "/bin/sh".into(),
            "-c".into(),
            "echo '{\"$message_type\":\"artifact\"}' >&2; exit 3".into(),
        ],
        env: BTreeMap::new(),
        cwd: t.path().to_owned(),
    };
    let e = run_rustc(&inv, "smokelib").unwrap_err();
    assert_eq!(e.0, "could not compile `smokelib` (exit status: 3)");
    let inv = Invocation {
        argv: vec!["/bin/sh".into(), "-c".into(), "kill -SEGV $$".into()],
        ..inv
    };
    let e = run_rustc(&inv, "x").unwrap_err();
    assert!(e.0.contains("signal: 11"), "{e}");
}
