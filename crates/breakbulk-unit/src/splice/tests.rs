use std::collections::BTreeMap;

use super::*;
use crate::directives::{LibraryPath, LinkArg};

fn lit(s: &str) -> RenderedArg {
    RenderedArg::Literal(s.into())
}

fn sp(run: &str, kind: SpliceKind) -> RenderedArg {
    RenderedArg::Splice(Splice {
        splice: run.into(),
        kind,
        bin: None,
    })
}

fn sp_bin(run: &str, bin: &str) -> RenderedArg {
    RenderedArg::Splice(Splice {
        splice: run.into(),
        kind: SpliceKind::RustcLinkArgBin,
        bin: Some(bin.into()),
    })
}

fn path(value: &str, in_out_dir: bool) -> LibraryPath {
    LibraryPath {
        value: value.into(),
        in_out_dir,
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
fn link_search_sorts_inside_before_outside() {
    // Cargo: all paths of all runs, stable-sorted CargoArtifact first.
    let got = expand(&[
        lit("before"),
        sp("/a", SpliceKind::RustcLinkSearch),
        sp("/b", SpliceKind::RustcLinkSearch),
        lit("-L"),
        lit("/override"),
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
            "/b-ext",
            "-L",
            "/override"
        ]
    );
}

#[test]
fn link_search_must_be_adjacent() {
    let e = expand(&[
        sp("/a", SpliceKind::RustcLinkSearch),
        lit("x"),
        sp("/b", SpliceKind::RustcLinkSearch),
    ])
    .unwrap_err();
    assert!(e.0.contains("not adjacent"), "{e}");
}

#[test]
fn link_args_keep_printed_order_across_kinds() {
    // A bin unit: the stub printed arg, then arg-bins, then arg-bin=app, so
    // the trace has them in that order; the script printed bins first.
    let got = expand(&[
        sp("/a", SpliceKind::RustcLinkLib),
        sp("/a", SpliceKind::RustcLinkArg),
        sp("/a", SpliceKind::RustcLinkArgBins),
        sp_bin("/a", "app"),
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
    let got = expand(&[
        sp("/a", SpliceKind::RustcLinkArgTests),
        sp("/a", SpliceKind::RustcLinkArg),
    ])
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
fn link_args_must_be_adjacent_per_run() {
    let e = expand(&[
        sp("/a", SpliceKind::RustcLinkArg),
        sp("/a", SpliceKind::RustcLinkLib),
        sp("/a", SpliceKind::RustcLinkArgBins),
    ])
    .unwrap_err();
    assert!(
        e.0.contains("rustc-link-arg splices from /a are not adjacent"),
        "{e}"
    );
    // Different runs may follow each other.
    expand(&[
        sp("/a", SpliceKind::RustcLinkArg),
        sp("/b", SpliceKind::RustcLinkArg),
    ])
    .unwrap();
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
        expand(&[sp("/a", SpliceKind::RustcLinkArgBin)])
            .unwrap_err()
            .0
            .contains("`bin`")
    );
    let bad_bin = RenderedArg::Splice(Splice {
        splice: "/a".into(),
        kind: SpliceKind::RustcCfg,
        bin: Some("x".into()),
    });
    assert!(expand(&[bad_bin]).is_err());
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
            sp("/e", SpliceKind::RustcLinkSearch),
            sp("/e", SpliceKind::RustcLinkArg),
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
    let s = |run: &str| Splice {
        splice: run.to_owned(),
        kind: SpliceKind::RustcEnv,
        bin: None,
    };
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
