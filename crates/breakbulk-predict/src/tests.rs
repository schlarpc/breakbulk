use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;

/// A view: files written under a temporary directory, removed on drop.
struct View(PathBuf);

impl View {
    fn new(files: &[(&str, &str)]) -> View {
        static N: AtomicUsize = AtomicUsize::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let p =
            std::env::temp_dir().join(format!("breakbulk-predict-test-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        for (f, text) in files {
            let path = p.join(f);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
        std::fs::create_dir_all(&p).unwrap();
        View(p)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for View {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn files(p: &Prediction) -> Vec<&str> {
    p.files.iter().map(String::as_str).collect()
}

fn reasons(f: &[Fallback]) -> Vec<&Reason> {
    f.iter().map(|f| &f.reason).collect()
}

/// The crate root `c/src/lib.rs` of package `c`.
fn lib(files: &[(&str, &str)]) -> Prediction {
    let v = View::new(files);
    predict_crate(v.path(), "c/src/lib.rs", "c")
}

#[test]
fn module_tree_follows_rustc_ownership() {
    let p = lib(&[
        ("c/Cargo.toml", ""),
        ("c/README.md", ""),
        ("c/src/lib.rs", "mod a; pub mod c;"),
        // a.rs is not a mod.rs file: its submodules are in a/.
        ("c/src/a.rs", "mod b;"),
        ("c/src/a/b.rs", ""),
        ("c/src/b.rs", "// not a's b"),
        ("c/src/c/mod.rs", "mod d;"),
        ("c/src/c/d.rs", ""),
        ("c/src/unused.rs", ""),
    ]);
    assert_eq!(
        files(&p),
        [
            "c/src/a.rs",
            "c/src/a/b.rs",
            "c/src/c/d.rs",
            "c/src/c/mod.rs",
            "c/src/lib.rs"
        ]
    );
    assert!(p.fallback.is_empty());
}

#[test]
fn both_candidates_are_kept() {
    // rustc fails with E0761 when both exist; the view keeps both so that
    // it still does.
    let p = lib(&[
        ("c/src/lib.rs", "mod x;"),
        ("c/src/x.rs", ""),
        ("c/src/x/mod.rs", ""),
    ]);
    assert_eq!(files(&p), ["c/src/lib.rs", "c/src/x.rs", "c/src/x/mod.rs"]);
}

#[test]
fn cfg_out_module_is_kept_when_it_exists() {
    let p = lib(&[
        (
            "c/src/lib.rs",
            "#[cfg(windows)] mod win; #[cfg(unix)] mod nix;",
        ),
        ("c/src/win.rs", ""),
    ]);
    assert_eq!(files(&p), ["c/src/lib.rs", "c/src/win.rs"]);
}

#[test]
fn path_attribute_is_relative_to_the_module_directory() {
    let p = lib(&[
        ("c/src/lib.rs", "mod a;"),
        // In a/… a non-mod-rs file, #[path] is relative to src/, not src/a/.
        ("c/src/a.rs", "#[path = \"impl/x.rs\"] mod x;"),
        // A #[path] file is a mod.rs file: its submodules are siblings.
        ("c/src/impl/x.rs", "mod y;"),
        ("c/src/impl/y.rs", ""),
        // The default candidates are not loaded when #[path] is plain.
        ("c/src/a/x.rs", ""),
    ]);
    assert_eq!(
        files(&p),
        [
            "c/src/a.rs",
            "c/src/impl/x.rs",
            "c/src/impl/y.rs",
            "c/src/lib.rs"
        ]
    );
}

#[test]
fn cfg_attr_path_keeps_every_alternative() {
    let p = lib(&[
        (
            "c/src/lib.rs",
            r#"
            #[cfg_attr(target_arch = "x86_64", path = "arch/x86.rs")]
            #[cfg_attr(all(unix, feature = "a"), cfg_attr(target_os = "linux", path = "arch/linux.rs"))]
            mod arch;
            "#,
        ),
        ("c/src/arch/x86.rs", ""),
        ("c/src/arch/linux.rs", ""),
        ("c/src/arch.rs", ""),
    ]);
    assert_eq!(
        files(&p),
        [
            "c/src/arch.rs",
            "c/src/arch/linux.rs",
            "c/src/arch/x86.rs",
            "c/src/lib.rs"
        ]
    );
}

#[test]
fn inline_modules_push_their_directory() {
    let p = lib(&[
        (
            "c/src/lib.rs",
            "mod a; mod outer { mod inner { mod x; } } #[path = \"p\"] mod q { mod y; }",
        ),
        ("c/src/outer/inner/x.rs", ""),
        ("c/src/p/y.rs", ""),
        // In a non-mod-rs file the relative offset comes first: a/n/z.rs.
        ("c/src/a.rs", "mod n { mod z; }"),
        ("c/src/a/n/z.rs", ""),
    ]);
    assert_eq!(
        files(&p),
        [
            "c/src/a.rs",
            "c/src/a/n/z.rs",
            "c/src/lib.rs",
            "c/src/outer/inner/x.rs",
            "c/src/p/y.rs"
        ]
    );
}

#[test]
fn module_files_in_blocks_need_a_path() {
    let p = lib(&[
        (
            "c/src/lib.rs",
            "fn f() { mod nope; #[path = \"yes.rs\"] mod yes; }",
        ),
        ("c/src/nope.rs", ""),
        ("c/src/yes.rs", ""),
    ]);
    assert_eq!(files(&p), ["c/src/lib.rs", "c/src/yes.rs"]);
}

#[test]
fn includes() {
    let p = lib(&[
        (
            "c/src/lib.rs",
            r#"
            #![doc = include_str!("../README.md")]
            #![cfg_attr(docsrs, doc = include_str!("../docs/extra.md"))]
            #![debugger_visualizer(natvis_file = "../c.natvis")]
            const A: &str = include_str!("data/a.txt");
            const B: &[u8] = std::include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/b.bin"));
            const C: &str = include_str!(concat!(env!("OUT_DIR"), "/gen.txt"));
            include!(concat!(env!("OUT_DIR"), "/gen.rs"));
            include!("parts/p.rs");
            "#,
        ),
        // An included file's includes and modules are relative to it.
        (
            "c/src/parts/p.rs",
            "const D: &str = include_str!(\"d.txt\"); mod m;",
        ),
        ("c/src/parts/m.rs", ""),
        ("c/src/m.rs", ""),
    ]);
    assert_eq!(
        files(&p),
        [
            "c/README.md",
            "c/assets/b.bin",
            "c/c.natvis",
            "c/docs/extra.md",
            "c/src/data/a.txt",
            "c/src/lib.rs",
            "c/src/parts/d.txt",
            "c/src/parts/m.rs",
            "c/src/parts/p.rs"
        ]
    );
    assert!(p.fallback.is_empty(), "{:?}", p.fallback);
}

#[test]
fn included_expression_file() {
    let p = lib(&[
        ("c/src/lib.rs", "const T: [u8; 2] = include!(\"t.in\");"),
        ("c/src/t.in", "[1, 2]"),
    ]);
    assert_eq!(files(&p), ["c/src/lib.rs", "c/src/t.in"]);
    assert!(p.fallback.is_empty());
}

#[test]
fn non_literal_include_falls_back() {
    let p = lib(&[(
        "c/src/lib.rs",
        "const A: &str = include_str!(env!(\"DATA\"));",
    )]);
    assert_eq!(
        reasons(&p.fallback),
        [&Reason::NonLiteralInclude("include_str".into())]
    );
}

#[test]
fn modules_in_macro_arguments_expand_in_place() {
    let p = lib(&[
        (
            "c/src/lib.rs",
            r#"
            cfg_if::cfg_if! {
                if #[cfg(unix)] {
                    #[path = "sys/unix.rs"] mod imp;
                } else {
                    mod other;
                    mod nested { mod deep; }
                    const X: &str = include_str!("x.txt");
                }
            }
            "#,
        ),
        ("c/src/sys/unix.rs", ""),
        ("c/src/other.rs", ""),
        ("c/src/nested/deep.rs", ""),
    ]);
    assert_eq!(
        files(&p),
        [
            "c/src/lib.rs",
            "c/src/nested/deep.rs",
            "c/src/other.rs",
            "c/src/sys/unix.rs",
            "c/src/x.txt"
        ]
    );
    assert!(p.fallback.is_empty());
}

#[test]
fn macro_rules_bodies_are_opaque() {
    let p = lib(&[(
        "c/src/lib.rs",
        "macro_rules! m { ($n:ident) => { mod $n; } } macro_rules! t { () => { mod types; } }",
    )]);
    assert_eq!(
        reasons(&p.fallback),
        [&Reason::MacroGeneratedMod, &Reason::InMacroRules]
    );
    // A macro_rules body with neither is fine.
    let p = lib(&[("c/src/lib.rs", "macro_rules! m { () => { fn f() {} } }")]);
    assert!(p.fallback.is_empty());
}

#[test]
fn literals_do_not_confuse_the_parser() {
    let p = lib(&[
        (
            "c/src/lib.rs",
            "const S: &str = r#\"mod fake; { include_str!(\"x\") \"#; const C: char = '{'; mod real;",
        ),
        ("c/src/real.rs", ""),
        ("c/src/fake.rs", ""),
    ]);
    assert_eq!(files(&p), ["c/src/lib.rs", "c/src/real.rs"]);
}

#[test]
fn parse_failure_falls_back() {
    let p = lib(&[("c/src/lib.rs", "fn f( {")]);
    assert!(matches!(reasons(&p.fallback)[..], [Reason::Parse(_)]));
}

#[test]
fn paths_outside_the_view_are_dropped() {
    let p = lib(&[(
        "c/src/lib.rs",
        "const A: &str = include_str!(\"../../../outside\");",
    )]);
    assert_eq!(files(&p), ["c/src/lib.rs"]);
    assert!(p.fallback.is_empty());
}

fn run(files: &[(&str, &str)]) -> RunPrediction {
    let v = View::new(files);
    predict_build_script_run(v.path(), "c/build.rs", "c")
}

#[test]
fn run_declares_literal_paths() {
    let r = run(&[
        (
            "c/build.rs",
            r#"
            include!("../common/build_common.rs");
            fn main() {
                println!("cargo:rerun-if-changed=build.rs");
                println!("cargo::rerun-if-changed=proto/");
                println!("cargo:rerun-if-env-changed=CC");
            }
            "#,
        ),
        (
            "common/build_common.rs",
            "fn common() { println!(\"cargo:rerun-if-changed=../common/x.h\"); }",
        ),
    ]);
    assert_eq!(
        r.declared.iter().collect::<Vec<_>>(),
        ["c/build.rs", "c/proto", "common/x.h"]
    );
    assert!(r.fallback.is_empty(), "{:?}", r.fallback);
}

#[test]
fn run_with_only_env_directives_declares_nothing() {
    let r = run(&[(
        "c/build.rs",
        "fn main() { println!(\"cargo:rerun-if-env-changed=X\"); }",
    )]);
    assert!(r.declared.is_empty());
    assert!(r.fallback.is_empty());
}

#[test]
fn run_without_directives_needs_the_whole_package() {
    let r = run(&[("c/build.rs", "fn main() {}")]);
    assert_eq!(reasons(&r.fallback), [&Reason::NoRerunIf]);
}

#[test]
fn run_with_computed_paths_falls_back() {
    let r = run(&[(
        "c/build.rs",
        r#"fn main() { for p in ["a", "b"] { println!("cargo:rerun-if-changed={p}"); } }"#,
    )]);
    assert!(matches!(
        reasons(&r.fallback)[..],
        [Reason::NonLiteralRerunIfChanged(_)]
    ));
    let r = run(&[(
        "c/build.rs",
        r#"fn main() { println!("cargo:{}={}", "rerun-if-changed", "x"); }"#,
    )]);
    assert!(matches!(
        reasons(&r.fallback)[..],
        [Reason::UnreadableRerunIfChanged(_), Reason::NoRerunIf]
    ));
}
