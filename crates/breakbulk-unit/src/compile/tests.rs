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
        env_append: Default::default(),
        env_layers: Vec::new(),
        env_splices: vec![],
        dylib_path_from: vec![],
        dylib_path: None,
        cwd: "/nix/store/x-src".into(),
        outputs: vec![OutputRule::file("app-1", "out")],
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
    // Cargo's trim-paths remaps are in the arguments (no remaps of
    // breakbulk's own): the scope still applies to them.
    u.remap.clear();
    assert_eq!(
        &added_args(&u, &dirs)[4..],
        ["--remap-path-scope=macro,diagnostics"]
    );
    // No scope: no flag.
    u.remap_scope = None;
    assert_eq!(added_args(&u, &dirs).len(), 4);
}

#[test]
fn invocation_expands_splices_and_env() {
    let mut u = unit(&["--crate-name", "app"]);
    let flags = "/nix/store/r-flags".to_owned();
    u.args.push(RenderedArg::Splice(Splice::new(
        flags.clone(),
        SpliceKind::RustcCfg,
    )));
    u.args.push(RenderedArg::Splice(Splice::search(
        flags.clone(),
        crate::spec::SearchIn::Out,
    )));
    u.env_splices
        .push(Splice::new(flags.clone(), SpliceKind::RustcEnv));
    u.env.insert("CARGO_PKG_NAME".into(), "app".into());
    u.env.insert("NUM_JOBS".into(), "64".into());
    let d = BuildOutput {
        cfgs: vec!["smoke".into()],
        library_paths: vec![LibraryPath {
            value: "native=/nix/store/r-out/native".into(),
            in_out_dir: true,
            in_build_dir: true,
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
    u.env_splices.push(Splice::new(
        flags.display().to_string(),
        SpliceKind::RustcEnv,
    ));
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
    link_deps(&[x.clone(), y.clone(), x.clone()], &[], &deps).unwrap();
    assert_eq!(
        std::fs::read_to_string(deps.join("libx-1.rmeta")).unwrap(),
        "x"
    );
    assert_eq!(
        std::fs::read_to_string(deps.join("liby-1.rlib")).unwrap(),
        "y"
    );
    // Recreated from scratch.
    link_deps(std::slice::from_ref(&y), &[], &deps).unwrap();
    assert!(!deps.join("libx-1.rmeta").exists());
    // Same name, different files.
    let x2 = b.join("libx-1.rmeta").display().to_string();
    assert!(
        link_deps(&[x, x2], &[], &deps)
            .unwrap_err()
            .0
            .contains("two dependencies")
    );
    let missing = t.path().join("gone.rlib").display().to_string();
    assert!(
        link_deps(&[missing], &[], &deps)
            .unwrap_err()
            .0
            .contains("does not exist")
    );
}

#[test]
fn deps_directory_links_side_files() {
    let t = TempDir::new("deps-side");
    let a = t.path().join("a");
    std::fs::create_dir_all(&a).unwrap();
    for f in ["libx-1.rmeta", "libx-1.rlib", "libx-1.vir", "libx-1.other"] {
        std::fs::write(a.join(f), f).unwrap();
    }
    let deps = t.path().join("deps");
    let crates = ["libx-1.rmeta", "libx-1.rlib"].map(|f| a.join(f).display().to_string());
    link_deps(&crates, &[".vir"], &deps).unwrap();
    // Once, though both crate files have the stem.
    assert_eq!(
        std::fs::read_to_string(deps.join("libx-1.vir")).unwrap(),
        "libx-1.vir"
    );
    assert!(!deps.join("libx-1.other").exists());
    // A crate without a side file links without one.
    std::fs::remove_file(a.join("libx-1.vir")).unwrap();
    link_deps(&crates, &[".vir"], &deps).unwrap();
    assert!(!deps.join("libx-1.vir").exists());
}

fn file(name: &str, output: &str) -> OutputRule {
    OutputRule::file(name, output)
}

/// A file rustc writes as `written`, stored as `stored`.
fn uplifted(written: &str, stored: &str, output: &str) -> OutputRule {
    OutputRule {
        stored: Some(stored.to_owned()),
        ..OutputRule::file(written, output)
    }
}

fn beside(suffix: &str) -> OutputRule {
    OutputRule::suffix(suffix, OutputInto::Beside)
}

fn dep_info() -> OutputRule {
    OutputRule::suffix(".d", OutputInto::Discard)
}

/// Every target's debuginfo side files at once, into `debug`.
fn debug_rules() -> Vec<OutputRule> {
    [".pdb", ".dwp", ".dwo", ".dSYM"]
        .map(|s| OutputRule::suffix(s, OutputInto::Output("debug".into())))
        .into()
}

#[test]
fn outputs_are_moved() {
    let t = TempDir::new("outputs");
    let from = t.path().join("out");
    std::fs::create_dir_all(&from).unwrap();
    for f in ["libx-1.rmeta", "libx-1.rlib", "x-1.d", "stray.o"] {
        std::fs::write(from.join(f), f).unwrap();
    }
    let rules = [
        file("libx-1.rmeta", "rmeta"),
        file("libx-1.rlib", "rlib"),
        dep_info(),
    ];
    let root = t.path().to_owned();
    let dest = |o: &str| Ok(root.join(format!("drv-{o}")));
    collect_outputs(&rules, &from, dest).unwrap();
    assert_eq!(
        std::fs::read_to_string(t.path().join("drv-rmeta/libx-1.rmeta")).unwrap(),
        "libx-1.rmeta"
    );
    assert!(t.path().join("drv-rlib/libx-1.rlib").exists());
    assert!(!from.join("libx-1.rlib").exists());
    // Dep-info is discarded; an unmatched file stays behind.
    assert!(from.join("x-1.d").exists());
    assert!(!t.path().join("drv-rmeta/x-1.d").exists());

    // An output that a suffix rule names is created though nothing goes
    // there.
    let rules = [
        file("stray.o", "out"),
        OutputRule::suffix(".none", OutputInto::Output("rmeta".into())),
    ];
    let root2 = t.path().join("second");
    let dest = |o: &str| Ok(root2.join(o));
    collect_outputs(&rules, &from, dest).unwrap();
    assert!(t.path().join("second/out/stray.o").exists());
    assert!(t.path().join("second/rmeta").is_dir());

    let e = collect_outputs(&[file("app-1", "out")], &from, |o| Ok(t.path().join(o))).unwrap_err();
    assert!(e.0.contains("did not write `app-1`"), "{e}");
    assert!(e.0.contains("x-1.d"), "{e}");
}

#[test]
fn side_files_go_beside_their_crate_file() {
    let t = TempDir::new("side-files");
    let from = t.path().join("out");
    std::fs::create_dir_all(&from).unwrap();
    for f in [
        "libx-1.rmeta",
        "libx-1.rlib",
        "libx-1.vir",
        "libx-1-simple.vir",
        "liby-2.vir",
        "libx-1.other",
    ] {
        std::fs::write(from.join(f), f).unwrap();
    }
    let rules = [
        file("libx-1.rmeta", "rmeta"),
        file("libx-1.rlib", "rlib"),
        beside(".vir"),
    ];
    let root = t.path().join("drv");
    collect_outputs(&rules, &from, |o: &str| Ok(root.join(o))).unwrap();
    // Into every output whose file has the stem: an rlib dependent finds
    // it too.
    for o in ["rmeta", "rlib"] {
        assert_eq!(
            std::fs::read_to_string(root.join(o).join("libx-1.vir")).unwrap(),
            "libx-1.vir"
        );
    }
    // Another stem, or an extension not asked for, stays behind.
    for o in ["rmeta", "rlib"] {
        for f in ["libx-1-simple.vir", "liby-2.vir", "libx-1.other"] {
            assert!(!root.join(o).join(f).exists(), "{o}/{f}");
        }
    }
    assert_eq!(beside_suffixes(&rules), [".vir"]);
    assert_eq!(stored_in(&rules, "rmeta"), ["libx-1.rmeta"]);

    // An uplifted file's side file takes its stored stem.
    std::fs::write(from.join("my_app-1"), "bin").unwrap();
    std::fs::write(from.join("my_app-1.vir"), "vir").unwrap();
    let rules = [uplifted("my_app-1", "my-app", "out"), beside(".vir")];
    let root = t.path().join("drv-bin");
    collect_outputs(&rules, &from, |o: &str| Ok(root.join(o))).unwrap();
    assert!(root.join("out/my-app.vir").is_file());
}

#[test]
fn uplifted_bin_is_stored_under_its_cargo_name() {
    let t = TempDir::new("uplifted");
    let from = t.path().join("out");
    std::fs::create_dir_all(&from).unwrap();
    for f in ["my_app-1", "my_app-1.dwp", "my_app-1.d"] {
        std::fs::write(from.join(f), f).unwrap();
    }
    let mut rules = vec![uplifted("my_app-1", "my-app", "out"), dep_info()];
    rules.extend(debug_rules());
    let root = t.path().join("drv");
    collect_outputs(&rules, &from, |o: &str| Ok(root.join(o))).unwrap();
    assert_eq!(
        std::fs::read_to_string(root.join("out/my-app")).unwrap(),
        "my_app-1"
    );
    assert!(!root.join("out/my_app-1").exists());
    // Side files keep rustc's names; the bin is not reported as unlisted.
    assert!(root.join("debug/my_app-1.dwp").exists());
    assert!(!from.join("my_app-1").exists());
    assert_eq!(stored_in(&rules, "out"), ["my-app"]);

    let e = collect_outputs(&rules, &from, |o: &str| Ok(root.join(o))).unwrap_err();
    assert!(e.0.contains("did not write `my_app-1`"), "{e}");
}

#[test]
fn debug_side_files_go_to_debug() {
    let t = TempDir::new("debug-side");
    let from = t.path().join("out");
    std::fs::create_dir_all(&from).unwrap();
    for f in [
        "app.exe",
        "app.pdb",
        "app-1.dwp",
        "app-1.app.0.rcgu.dwo",
        "app.d",
        "x.o",
    ] {
        std::fs::write(from.join(f), f).unwrap();
    }
    let mut rules = vec![file("app.exe", "out"), dep_info()];
    rules.extend(debug_rules());
    let root = t.path().join("drv");
    let dest = |o: &str| Ok(root.join(o));
    collect_outputs(&rules, &from, dest).unwrap();
    assert!(root.join("out/app.exe").exists());
    let mut debug: Vec<String> = std::fs::read_dir(root.join("debug"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    debug.sort();
    assert_eq!(debug, ["app-1.app.0.rcgu.dwo", "app-1.dwp", "app.pdb"]);
    assert!(
        from.join("x.o").exists(),
        "other unlisted files stay behind"
    );

    // An Apple `.dSYM` bundle is a directory, moved whole.
    let dwarf = from.join("app-1.dSYM/Contents/Resources/DWARF");
    std::fs::create_dir_all(&dwarf).unwrap();
    std::fs::write(dwarf.join("app-1"), "dwarf").unwrap();
    std::fs::write(from.join("app-1.dSYM/Contents/Info.plist"), "plist").unwrap();
    let root = t.path().join("drv-dsym");
    collect_outputs(&debug_rules(), &from, |o: &str| Ok(root.join(o))).unwrap();
    assert_eq!(
        std::fs::read_to_string(root.join("debug/app-1.dSYM/Contents/Resources/DWARF/app-1"))
            .unwrap(),
        "dwarf"
    );
    assert!(root.join("debug/app-1.dSYM/Contents/Info.plist").is_file());
    assert!(!from.join("app-1.dSYM").exists());

    // Without debug rules (a unit without a `debug` output), side files
    // stay behind.
    std::fs::write(from.join("lib.pdb"), "").unwrap();
    let root = t.path().join("drv2");
    collect_outputs(&[file("x.o", "out")], &from, |o: &str| Ok(root.join(o))).unwrap();
    assert!(!root.join("debug").exists());
    assert!(from.join("lib.pdb").exists());
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
    let e = run_rustc(&inv, "smokelib", &|_| Vec::new()).unwrap_err();
    assert_eq!(e.0, "could not compile `smokelib` (exit status: 3)");
    let inv = Invocation {
        argv: vec!["/bin/sh".into(), "-c".into(), "kill -SEGV $$".into()],
        ..inv
    };
    let e = run_rustc(&inv, "x", &|_| Vec::new()).unwrap_err();
    assert!(e.0.contains("signal: 11"), "{e}");
}
