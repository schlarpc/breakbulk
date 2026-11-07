use std::collections::BTreeMap;

use super::*;
use crate::directives::{LibraryPath, LinkArg};
use crate::spec::LinkArgKind;

fn lit(s: &str) -> RenderedArg {
    RenderedArg::Literal(s.into())
}

fn sp(run: &str, kind: SpliceKind) -> RenderedArg {
    RenderedArg::Splice(Splice::new(run.into(), kind))
}

fn search(run: &str, search: SearchIn) -> RenderedArg {
    RenderedArg::Splice(Splice::search(run.into(), search))
}

fn link_args(run: &str, kinds: &[LinkArgKind]) -> RenderedArg {
    RenderedArg::Splice(Splice::link_args(run.into(), kinds.iter().cloned()))
}

fn k(kind: SpliceKind) -> LinkArgKind {
    LinkArgKind::new(kind)
}

fn path(value: &str, in_out_dir: bool) -> LibraryPath {
    LibraryPath {
        value: value.into(),
        in_out_dir,
        in_build_dir: in_out_dir,
    }
}

fn la(kind: SpliceKind, bin: Option<&str>, value: &str) -> LinkArg {
    LinkArg {
        kind,
        bin: bin.map(Into::into),
        value: value.into(),
    }
}

fn run_a() -> BuildOutput {
    BuildOutput {
        cfgs: vec!["a1".into(), "a2".into()],
        check_cfgs: vec!["cfg(a1)".into()],
        library_links: vec!["static=a".into(), "a".into()],
        library_paths: vec![
            path("/usr/lib", false),
            path("native=/out-a/lib", true),
            path("/opt/lib", false),
            path("/out-a", true),
        ],
        linker_args: vec![
            la(SpliceKind::RustcLinkArgBins, None, "bins1"),
            la(SpliceKind::RustcLinkArg, None, "all1"),
            la(SpliceKind::RustcLinkArgTests, None, "tests1"),
            la(SpliceKind::RustcLinkArgBin, Some("app"), "app1"),
            la(SpliceKind::RustcLinkArgBin, Some("other"), "other1"),
            la(SpliceKind::RustcLinkArg, None, "all2"),
        ],
        env: vec![
            ("K".into(), "1".into()),
            ("CARGO_PKG_NAME".into(), "override".into()),
            ("K".into(), "2".into()),
        ],
        ..Default::default()
    }
}

fn run_b() -> BuildOutput {
    BuildOutput {
        library_paths: vec![path("/b-ext", false), path("/out-b", true)],
        env: vec![("K".into(), "b".into()), ("B".into(), "1".into())],
        ..Default::default()
    }
}

fn dirs() -> BTreeMap<String, BuildOutput> {
    BTreeMap::from([("/a".to_owned(), run_a()), ("/b".to_owned(), run_b())])
}

fn expand(args: &[RenderedArg]) -> Result<Vec<String>, SpliceError> {
    let d = dirs();
    expand_args(args, |p| d.get(p))
}

#[test]
fn wrapping_table() {
    let w = |k| wrap(k, "v").map(|a| a.to_vec());
    assert_eq!(
        w(SpliceKind::RustcCfg),
        Some(vec!["--cfg".into(), "v".into()])
    );
    assert_eq!(
        w(SpliceKind::RustcCheckCfg),
        Some(vec!["--check-cfg".into(), "v".into()])
    );
    assert_eq!(
        w(SpliceKind::RustcLinkLib),
        Some(vec!["-l".into(), "v".into()])
    );
    assert_eq!(
        w(SpliceKind::RustcLinkSearch),
        Some(vec!["-L".into(), "v".into()])
    );
    assert_eq!(w(SpliceKind::RustcEnv), None);
    for k in SpliceKind::ALL.into_iter().filter(|k| k.is_link_arg()) {
        assert_eq!(w(k), Some(vec!["-C".into(), "link-arg=v".into()]));
    }
}

#[test]
fn simple_kinds_expand_in_place() {
    let got = expand(&[
        lit("--crate-name"),
        lit("x"),
        sp("/a", SpliceKind::RustcCfg),
        sp("/a", SpliceKind::RustcCheckCfg),
        sp("/b", SpliceKind::RustcCfg),
        lit("-l"),
        lit("literal"),
        sp("/a", SpliceKind::RustcLinkLib),
    ])
    .unwrap();
    assert_eq!(
        got,
        [
            "--crate-name",
            "x",
            "--cfg",
            "a1",
            "--cfg",
            "a2",
            "--check-cfg",
            "cfg(a1)",
            "-l",
            "literal",
            "-l",
            "static=a",
            "-l",
            "a"
        ]
    );
}

#[test]
fn link_search_expands_each_class_where_cargo_put_it() {
    // As Cargo emits them: every run's inside paths, then every run's
    // outside paths, with a `links` override's `-L` among the outside ones
    // in dependency order.
    let got = expand(&[
        lit("before"),
        search("/a", SearchIn::Out),
        search("/b", SearchIn::Out),
        search("/a", SearchIn::Other),
        lit("-L"),
        lit("/override"),
        search("/b", SearchIn::Other),
    ])
    .unwrap();
    assert_eq!(
        got,
        [
            "before",
            "-L",
            "native=/out-a/lib",
            "-L",
            "/out-a",
            "-L",
            "/out-b",
            "-L",
            "/usr/lib",
            "-L",
            "/opt/lib",
            "-L",
            "/override",
            "-L",
            "/b-ext",
        ]
    );
    // Each splice stands alone: no adjacency rule.
    let got = expand(&[
        search("/b", SearchIn::Other),
        lit("x"),
        search("/b", SearchIn::Out),
    ])
    .unwrap();
    assert_eq!(got, ["-L", "/b-ext", "x", "-L", "/out-b"]);
}

#[test]
fn link_args_keep_printed_order_across_kinds() {
    // A bin unit receives arg, arg-bins and arg-bin=app; the script printed
    // bins first.
    let got = expand(&[
        sp("/a", SpliceKind::RustcLinkLib),
        link_args(
            "/a",
            &[
                k(SpliceKind::RustcLinkArg),
                k(SpliceKind::RustcLinkArgBins),
                LinkArgKind::bin("app"),
            ],
        ),
        lit("end"),
    ])
    .unwrap();
    assert_eq!(
        got,
        [
            "-l",
            "static=a",
            "-l",
            "a",
            "-C",
            "link-arg=bins1",
            "-C",
            "link-arg=all1",
            "-C",
            "link-arg=app1",
            "-C",
            "link-arg=all2",
            "end"
        ]
    );
    // A test unit gets `rustc-link-arg` and `-tests` only.
    let got = expand(&[link_args(
        "/a",
        &[
            k(SpliceKind::RustcLinkArgTests),
            k(SpliceKind::RustcLinkArg),
        ],
    )])
    .unwrap();
    assert_eq!(
        got,
        [
            "-C",
            "link-arg=all1",
            "-C",
            "link-arg=tests1",
            "-C",
            "link-arg=all2"
        ]
    );
}

#[test]
fn shape_errors() {
    assert!(
        expand(&[sp("/a", SpliceKind::RustcEnv)])
            .unwrap_err()
            .0
            .contains("envSplices")
    );
    assert!(
        expand(&[
            sp("/a", SpliceKind::RustcCfg),
            sp("/a", SpliceKind::RustcCfg)
        ])
        .unwrap_err()
        .0
        .contains("twice")
    );
    assert!(
        expand(&[
            link_args("/a", &[k(SpliceKind::RustcLinkArg)]),
            link_args("/a", &[k(SpliceKind::RustcLinkArgBins)]),
        ])
        .unwrap_err()
        .0
        .contains("twice")
    );
    // One splice per sentinel kind and class.
    expand(&[search("/a", SearchIn::Out), search("/a", SearchIn::Other)]).unwrap();
    assert!(
        expand(&[search("/a", SearchIn::Out), search("/a", SearchIn::Out)])
            .unwrap_err()
            .0
            .contains("twice")
    );
    // Old shapes: a link-arg kind as the splice kind, a search without `in`.
    assert!(expand(&[sp("/a", SpliceKind::RustcLinkArgBins)]).is_err());
    assert!(expand(&[sp("/a", SpliceKind::RustcLinkSearch)]).is_err());
    assert!(expand(&[link_args("/a", &[])]).is_err());
    assert!(
        expand(&[sp("/missing", SpliceKind::RustcCfg)])
            .unwrap_err()
            .0
            .contains("no directives for splice rustc-cfg from /missing")
    );
}

#[test]
fn empty_runs_expand_to_nothing() {
    let empty = BuildOutput::default();
    let got = expand_args(
        &[
            lit("a"),
            sp("/e", SpliceKind::RustcCfg),
            search("/e", SearchIn::Out),
            search("/e", SearchIn::Other),
            link_args("/e", &[k(SpliceKind::RustcLinkArg)]),
            lit("b"),
        ],
        |_| Some(&empty),
    )
    .unwrap();
    assert_eq!(got, ["a", "b"]);
}

#[test]
fn env_splices() {
    let d = dirs();
    let env = BTreeMap::from([
        ("CARGO_PKG_NAME".to_owned(), "ring".to_owned()),
        ("OUT_DIR".to_owned(), "/out-a".to_owned()),
    ]);
    let s = |run: &str| Splice::new(run.to_owned(), SpliceKind::RustcEnv);
    let got = expand_env(&env, &[s("/a"), s("/b")], |p| d.get(p)).unwrap();
    assert_eq!(
        got,
        BTreeMap::from([
            ("B".to_owned(), "1".to_owned()),
            ("CARGO_PKG_NAME".to_owned(), "override".to_owned()),
            ("K".to_owned(), "b".to_owned()),
            ("OUT_DIR".to_owned(), "/out-a".to_owned()),
        ])
    );
    // Order matters: the last run wins.
    let got = expand_env(&env, &[s("/b"), s("/a")], |p| d.get(p)).unwrap();
    assert_eq!(got["K"], "2");
    // Shape errors.
    let mut bad = s("/a");
    bad.kind = SpliceKind::RustcCfg;
    assert!(expand_env(&env, &[bad], |p| d.get(p)).is_err());
    assert!(expand_env(&env, &[s("/a"), s("/a")], |p| d.get(p)).is_err());
    assert!(expand_env(&env, &[s("/x")], |p| d.get(p)).is_err());
}

#[test]
fn dylib_paths_append_like_add_plugin_deps() {
    let mut up = path("native=/out-up/lib", false);
    up.in_build_dir = true; // inside an upstream run's OUT_DIR
    let a = BuildOutput {
        library_paths: vec![
            path("native=/out-a/lib", true),
            path("/usr/lib", false),
            up,
            path("native=/out-a/lib", true),
        ],
        ..BuildOutput::default()
    };
    let b = BuildOutput {
        library_paths: vec![path("/out-b", true)],
        ..BuildOutput::default()
    };
    let d = BTreeMap::from([("/a".to_owned(), a), ("/b".to_owned(), b)]);
    let runs = ["/a".to_owned(), "/b".to_owned()];
    let recorded = || BTreeMap::from([(DYLIB_PATH_VAR.to_owned(), "/sysroot/lib".to_owned())]);

    // Compiles and runs: after the recorded value, in run and printed
    // order, duplicates kept, upstream OUT_DIRs included.
    let mut env = recorded();
    expand_dylib_path(&mut env, &runs, |p| d.get(p)).unwrap();
    assert_eq!(
        env[DYLIB_PATH_VAR],
        "/sysroot/lib:/out-a/lib:/out-up/lib:/out-a/lib:/out-b"
    );
    let mut env = BTreeMap::new();
    expand_dylib_path(&mut env, &runs, |p| d.get(p)).unwrap();
    assert_eq!(
        env[DYLIB_PATH_VAR],
        "/out-a/lib:/out-up/lib:/out-a/lib:/out-b"
    );

    // Doctests: sorted by the printed value (`/out-b` before `native=…`),
    // duplicate values once, before the recorded value.
    let mut env = recorded();
    prepend_dylib_path(&mut env, &runs, |p| d.get(p)).unwrap();
    assert_eq!(
        env[DYLIB_PATH_VAR],
        "/out-b:/out-a/lib:/out-up/lib:/sysroot/lib"
    );

    // No runs: untouched.
    let mut env = recorded();
    expand_dylib_path(&mut env, &[], |p| d.get(p)).unwrap();
    assert_eq!(env, recorded());
    assert!(expand_dylib_path(&mut env, &["/x".to_owned()], |p| d.get(p)).is_err());
}
