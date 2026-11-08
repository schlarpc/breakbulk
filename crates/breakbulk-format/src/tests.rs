use std::collections::{BTreeMap, BTreeSet};

use breakbulk_unit::directives::{BuildOutput, LibraryPath};
use breakbulk_unit::spec::{RenderedArg, RenderedUnit};

use super::*;

const RING: &str = "registry+https://github.com/rust-lang/crates.io-index#ring@0.17.14";
const APP: &str = "path+file:///build/skeleton/app#0.1.0";

/// The example from "Plan format", filled in.
fn example_json() -> String {
    format!(
        r#"{{
  "version": 1,
  "kind": "build",
  "cargo": "1.96.1", "rustc": "1.96.1 (abc 2026-01-01)", "host": "x86_64-unknown-linux-gnu",
  "target": "wasm32-unknown-unknown",
  "variant": {{ "profile": "release", "features": ["b", "a"], "mode": "build" }},
  "skeletonRoot": "/build/skeleton", "trimPaths": false,
  "units": {{
    "c-ring": {{
      "kind": "compile",
      "package": "{RING}",
      "crate": {{ "name": "ring", "types": ["lib"], "edition": "2021" }},
      "platform": "target",
      "program": ["/nix/store/00000000000000000000000000000000-rustc/bin/rustc"],
      "args": ["--crate-name", "ring", [{{ "crateSrc": "{RING}", "rel": "src/lib.rs" }}],
               ["--extern", "cfg_if=", {{ "out": "c-cfgif", "output": "rmeta", "file": "libcfg_if-1.rmeta" }}],
               {{ "splice": "r-ring", "kind": "rustc-cfg" }},
               {{ "splice": "r-ring", "kind": "rustc-link-lib" }}],
      "env": {{ "CARGO_PKG_NAME": "ring", "OUT_DIR": [{{ "out": "r-ring", "output": "out" }}] }},
      "envSplices": [{{ "splice": "r-ring", "kind": "rustc-env" }}],
      "cwd": {{ "crateSrc": "{RING}", "rel": "" }},
      "outputs": {{ "rmeta": ["libring-1.rmeta"], "rlib": ["libring-1.rlib"] }}
    }},
    "c-cfgif": {{
      "kind": "compile",
      "package": "cfg-if",
      "crate": {{ "name": "cfg_if", "types": ["lib"], "edition": "2018" }},
      "platform": "target",
      "program": ["rustc"],
      "args": [],
      "env": {{}},
      "envSplices": [],
      "cwd": {{ "crateSrc": "cfg-if", "rel": "" }},
      "outputs": {{ "rmeta": ["libcfg_if-1.rmeta"], "rlib": ["libcfg_if-1.rlib"] }}
    }},
    "c-ring-build": {{
      "kind": "compile",
      "package": "{RING}",
      "crate": {{ "name": "build_script_build", "types": ["bin"], "edition": "2021" }},
      "platform": "host",
      "program": ["rustc"],
      "args": [],
      "env": {{}},
      "envSplices": [],
      "cwd": {{ "crateSrc": "{RING}", "rel": "" }},
      "outputs": {{ "bin": ["build_script_build-1"] }}
    }},
    "r-ring": {{
      "kind": "run", "package": "{RING}", "platform": "target", "links": "ring_core_0_17_14_",
      "script": {{ "out": "c-ring-build", "output": "bin" }},
      "env": {{ "TARGET": "wasm32-unknown-unknown" }},
      "cwd": {{ "crateSrc": "{RING}", "rel": "" }},
      "metadataFrom": [],
      "rustVersion": "1.66",
      "targets": [{{ "name": "ring", "kind": ["lib"] }}],
      "nightlyFeaturesAllowed": false
    }},
    "c-app": {{
      "kind": "compile",
      "package": "{APP}",
      "crate": {{ "name": "app", "types": ["bin"], "edition": "2024" }},
      "platform": "target",
      "program": ["rustc"],
      "args": [[{{ "src": "{APP}", "rel": "src/main.rs" }}]],
      "env": {{}},
      "envSplices": [],
      "cwd": {{ "src": "{APP}", "rel": "" }},
      "outputs": {{ "bin": ["app-1"] }}
    }}
  }},
  "roots": [{{ "package": "{APP}", "target": "app", "kind": "bin", "unit": "c-app", "test": false }}]
}}"#
    )
}

fn example() -> Plan {
    Plan::from_json(&example_json()).unwrap()
}

fn compile<'a>(p: &'a mut Plan, id: &str) -> &'a mut CompileUnit {
    match p.units.get_mut(id) {
        Some(Unit::Compile(c)) => c,
        _ => panic!("{id} is not a compile unit"),
    }
}

fn run<'a>(p: &'a mut Plan, id: &str) -> &'a mut RunUnit {
    match p.units.get_mut(id) {
        Some(Unit::Run(r)) => r,
        _ => panic!("{id} is not a run unit"),
    }
}

fn opts() -> ValidationOptions {
    ValidationOptions {
        forbidden_paths: vec![
            "/build".into(),
            "/tmp/scratch".into(),
            "/homeless-shelter".into(),
        ],
    }
}

fn errors(p: &Plan) -> Vec<String> {
    match validate(p, &opts()) {
        Ok(()) => vec![],
        Err(e) => e.iter().map(ToString::to_string).collect(),
    }
}

fn assert_error(p: &Plan, needle: &str) {
    let e = errors(p);
    assert!(
        e.iter().any(|m| m.contains(needle)),
        "expected `{needle}` in {e:#?}"
    );
}

#[test]
fn example_parses_and_validates() {
    let p = example();
    assert_eq!(p.kind, PlanKind::Build);
    assert_eq!(p.variant.features.iter().collect::<Vec<_>>(), ["a", "b"]);
    let ring = match &p.units["c-ring"] {
        Unit::Compile(c) => c,
        _ => unreachable!(),
    };
    assert_eq!(
        ring.args[3],
        Arg::Concat(vec![
            Piece::Literal("--extern".into()),
            Piece::Literal("cfg_if=".into()),
            Piece::Ref(Reference::Out(OutRef {
                out: "c-cfgif".into(),
                output: "rmeta".into(),
                file: Some("libcfg_if-1.rmeta".into())
            }))
        ])
    );
    assert_eq!(errors(&p), Vec::<String>::new());
}

#[test]
fn canonical_json_is_sorted_compact_and_stable() {
    let p = example();
    let a = p.to_canonical_json();
    assert!(!a.contains('\n') && !a.contains(": "));
    assert!(a.starts_with(r#"{"cargo":"1.96.1","host":"#), "{a}");
    // Concatenated literals are merged in normal form. (The doc's example
    // array concatenates `--extern` and `cfg_if=` into one argument.)
    assert!(a.contains(r#"["--externcfg_if=",{"file":"#), "{a}");
    // Round trip is a fixed point.
    let b = Plan::from_json(&a).unwrap().to_canonical_json();
    assert_eq!(a, b);
    // Building the same plan in another order gives the same bytes.
    let mut q = example();
    let units: Vec<_> = std::mem::take(&mut q.units).into_iter().rev().collect();
    q.units.extend(units);
    run(&mut q, "r-ring").targets.insert(
        0,
        PackageTarget {
            name: "ring".into(),
            kind: vec!["lib".into()],
        },
    );
    assert_eq!(q.to_canonical_json(), a);
}

/// `roots` is a set (decision 9): read in any order and with repeats, it
/// is written sorted and once each, the same bytes as before it was typed
/// as a set.
#[test]
fn roots_are_a_set() {
    let a = example().to_canonical_json();
    let mut v: serde_json::Value = serde_json::from_str(&a).unwrap();
    let roots = v["roots"].as_array_mut().unwrap();
    let app = roots[0].clone();
    let mut other = app.clone();
    other["target"] = "aaa".into();
    *roots = vec![app.clone(), other, app];
    let p = Plan::from_json(&v.to_string()).unwrap();
    assert_eq!(p.roots.len(), 2);
    let c = p.to_canonical_json();
    let first = c.find(r#""target":"aaa""#).unwrap();
    let second = c.find(r#""target":"app""#).unwrap();
    assert!(first < second, "{c}");
    // One root again: the original bytes.
    let mut p = p;
    p.roots.retain(|r| r.target == "app");
    assert_eq!(p.to_canonical_json(), a);
}

#[test]
fn normal_form_of_concatenations() {
    let r = Piece::Ref(Reference::Src(SrcRef {
        src: "p".into(),
        rel: "x".into(),
    }));
    let l = |s: &str| Piece::Literal(s.into());
    assert_eq!(
        normalize_arg(Arg::Concat(vec![l("a"), l(""), l("b")])),
        Arg::Literal("ab".into())
    );
    assert_eq!(
        normalize_arg(Arg::Concat(vec![])),
        Arg::Literal(String::new())
    );
    assert_eq!(
        normalize_arg(Arg::Concat(vec![
            l("-L"),
            l(""),
            r.clone(),
            l("/"),
            l("lib")
        ])),
        Arg::Concat(vec![l("-L"), r.clone(), l("/lib")])
    );
    assert_eq!(
        normalize_text(Text::Concat(vec![r.clone()])),
        Text::Concat(vec![r])
    );
}

#[test]
fn schema_is_strict() {
    let bad = [
        // A bare reference is not an argument.
        (r#"{"crateSrc": "x", "rel": ""}"#, "args"),
        // Unknown fields in references and splices.
        (
            r#"[{"out": "c-cfgif", "output": "rmeta", "extra": 1}]"#,
            "args",
        ),
        (
            r#"{"splice": "r-ring", "kind": "rustc-cfg", "x": 1}"#,
            "args",
        ),
        (r#"{"splice": "r-ring", "kind": "rustc-bogus"}"#, "args"),
        (r#"1"#, "args"),
    ];
    for (arg, _) in bad {
        let json = example_json().replacen(
            r#""args": ["--crate-name""#,
            &format!(r#""args": [{arg}, "--crate-name""#),
            1,
        );
        assert!(Plan::from_json(&json).is_err(), "accepted {arg}");
    }
    let json = example_json().replacen(
        r#""trimPaths": false"#,
        r#""trimPaths": false, "extra": 1"#,
        1,
    );
    assert!(Plan::from_json(&json).is_err());
    let json = example_json().replacen(r#""version": 1"#, r#""version": 2"#, 1);
    assert!(matches!(Plan::from_json(&json), Err(PlanError::Version(2))));
}

#[test]
fn invariant_2_references_name_units() {
    let mut p = example();
    compile(&mut p, "c-ring").args.push(Arg::Splice(Splice::new(
        "r-nope".into(),
        SpliceKind::RustcCheckCfg,
    )));
    compile(&mut p, "c-ring").env.insert(
        "X".into(),
        Text::Concat(vec![Piece::Ref(Reference::Out(OutRef {
            out: "c-nope".into(),
            output: "rlib".into(),
            file: None,
        }))]),
    );
    compile(&mut p, "c-ring")
        .env_splices
        .push(Splice::new("c-cfgif".into(), SpliceKind::RustcEnv));
    run(&mut p, "r-ring")
        .metadata_from
        .insert("r-missing".into());
    p.roots = std::mem::take(&mut p.roots)
        .into_iter()
        .map(|mut r| {
            r.unit = "r-ring".into();
            r
        })
        .collect();
    assert_error(&p, "splice rustc-check-cfg names unknown unit r-nope");
    assert_error(&p, "env `X`: reference to unknown unit c-nope");
    assert_error(&p, "splice rustc-env names compile unit c-cfgif");
    assert_error(&p, "metadataFrom names unknown unit r-missing");
    assert_error(&p, "names unit r-ring, which is not a compile unit");
}

#[test]
fn reference_outputs_and_files() {
    let mut p = example();
    let c = compile(&mut p, "c-ring");
    let out = |out: &str, output: &str, file: Option<&str>| {
        Arg::Concat(vec![Piece::Ref(Reference::Out(OutRef {
            out: out.into(),
            output: output.into(),
            file: file.map(Into::into),
        }))])
    };
    c.args.push(out("c-cfgif", "bin", None));
    c.args.push(out("c-cfgif", "rlib", Some("libother.rlib")));
    c.args.push(out("r-ring", "flags", None));
    c.args
        .push(out("c-cfgif", "rlib", Some("libcfg_if-1.rlib")));
    c.args
        .push(Arg::Concat(vec![Piece::Ref(Reference::Src(SrcRef {
            src: APP.into(),
            rel: "/abs".into(),
        }))]));
    let e = errors(&p);
    assert_eq!(e.len(), 4, "{e:#?}");
    assert_error(&p, "unit c-cfgif has no output `bin`");
    assert_error(&p, "output `rlib` has no file `libother.rlib`");
    assert_error(&p, "reference to run unit r-ring must be output `out`");
    assert_error(&p, "`rel` must be relative");
}

#[test]
fn metadata_from_requires_links() {
    let mut p = example();
    let mut other = run(&mut p, "r-ring").clone();
    other.links = None;
    other.metadata_from.insert("r-ring".into());
    p.units.insert("r-other".into(), Unit::Run(other.clone()));
    assert_eq!(errors(&p), Vec::<String>::new());
    run(&mut p, "r-ring").metadata_from.insert("r-other".into());
    assert_error(
        &p,
        "metadataFrom names r-other, whose package declares no `links`",
    );
    run(&mut p, "r-ring").metadata_from = ["r-ring".to_owned()].into();
    assert_error(&p, "metadataFrom names the run itself");
}

#[test]
fn run_script_must_be_compile_output() {
    let mut p = example();
    run(&mut p, "r-ring").script = Reference::CrateSrc(CrateSrcRef {
        crate_src: RING.into(),
        rel: "build.rs".into(),
    });
    assert_error(&p, "script is not an output of a compile unit");
}

#[test]
fn splice_shapes() {
    let mut p = example();
    let sp = |kind| Arg::Splice(Splice::new("r-ring".into(), kind));
    let c = compile(&mut p, "c-ring");
    c.args.push(Arg::Splice(Splice::link_args(
        "r-ring".into(),
        [breakbulk_unit::spec::LinkArgKind::bin("nobin")],
    )));
    c.args.push(sp(SpliceKind::RustcEnv));
    c.env_splices
        .push(Splice::new("r-ring".into(), SpliceKind::RustcCfg));
    assert_error(
        &p,
        "names bin `nobin`, which run r-ring has no bin target for",
    );
    assert_error(&p, "envSplices entry from r-ring has kind rustc-cfg");
    assert_error(&p, "envSplices names r-ring twice");
    // check_arg_splices reports the first shape problem it finds.
    assert_error(&p, "rustc-env belongs in envSplices");
    let mut p = example();
    compile(&mut p, "c-ring")
        .args
        .push(sp(SpliceKind::RustcCfg));
    assert_error(&p, "splice rustc-cfg from r-ring appears twice");
    // Old one-splice-per-kind shapes are rejected.
    let mut p = example();
    compile(&mut p, "c-ring")
        .args
        .push(sp(SpliceKind::RustcLinkArgBins));
    assert_error(&p, "rustc-link-arg-bins is not a splice kind");
    let mut p = example();
    compile(&mut p, "c-ring")
        .args
        .push(sp(SpliceKind::RustcLinkSearch));
    assert_error(&p, "needs `in`");
}

#[test]
fn invariant_3_forbidden_literals() {
    let mut p = example();
    let c = compile(&mut p, "c-ring");
    c.args.push(Arg::Literal("--out-dir".into()));
    c.args
        .push(Arg::Literal("/tmp/scratch/wasm32/release/deps".into()));
    c.args.push(Arg::Literal("-Cincremental=/build/x".into()));
    c.args.push(Arg::Literal("--cfg".into()));
    c.args.push(Arg::Literal("__bb_r1_cfg".into()));
    c.env
        .insert("DEP_RING___BB".into(), Text::Literal("r1".into()));
    c.env
        .insert("HOME".into(), Text::Literal("/homeless-shelter".into()));
    c.program.push(Text::Literal("/build/skeleton/tool".into()));
    let e = errors(&p);
    assert_error(&p, "args[");
    assert!(
        e.iter()
            .any(|m| m.contains("forbidden path `/tmp/scratch`")),
        "{e:#?}"
    );
    assert!(
        e.iter()
            .any(|m| m.contains("forbidden path `/build`: `-Cincremental=/build/x`")),
        "{e:#?}"
    );
    assert!(
        e.iter()
            .any(|m| m.contains("sentinel token: `__bb_r1_cfg`")),
        "{e:#?}"
    );
    assert!(
        e.iter()
            .any(|m| m.contains("env name `DEP_RING___BB` contains a sentinel")),
        "{e:#?}"
    );
    assert!(
        e.iter()
            .any(|m| m.contains("env `HOME` contains the forbidden path `/homeless-shelter`")),
        "{e:#?}"
    );
    // The skeleton root is always forbidden, even without options.
    assert!(
        e.iter()
            .any(|m| m.contains("program[1] contains the forbidden path `/build/skeleton`")),
        "{e:#?}"
    );
}

#[test]
fn path_matching() {
    for (lit, yes) in [
        ("/build", true),
        ("/build/", true),
        ("/build/x", true),
        ("dependency=/build/x", true),
        ("--remap-path-prefix=/a=/build", true),
        ("-L/build/x", true),
        ("@/build/args", true),
        ("a:/build:b", true),
        ("/build.rs", false),
        ("/buildx", false),
        ("/nix/store/aaa-src/build/x.c", false),
        ("x/build", false),
        ("--L/build", false),
    ] {
        assert_eq!(contains_path(lit, "/build"), yes, "{lit}");
    }
    assert!(!contains_path("é/tmp/s", "/tmp/s"));
    assert!(contains_path("é=/tmp/s", "/tmp/s/"));
    assert!(!contains_path("anything", ""));
}

#[test]
fn sentinel_matching() {
    for (s, yes) in [
        ("__bb_r1_cfg", true),
        ("cfg(__bb_r1_ccfg)", true),
        ("__BB_R1_ENV=1", true),
        ("__bb=r1", true),
        ("DEP_X___BB", true),
        ("native=/o/__bb_r_search", true),
        ("__bbq", false),
        ("_bb_", false),
        ("bb", false),
    ] {
        assert_eq!(contains_sentinel(s), yes, "{s}");
    }
}

#[test]
fn store_paths_in_literals() {
    let p = example();
    let paths = literal_store_paths(&p, "/nix/store");
    assert_eq!(
        paths.into_iter().collect::<Vec<_>>(),
        ["/nix/store/00000000000000000000000000000000-rustc"]
    );
    let mut p = example();
    compile(&mut p, "c-app").args.push(Arg::Literal(
        "-Clinker=/nix/store/abc-cc/bin/cc,x=/nix/store/def-y".into(),
    ));
    let paths = literal_store_paths(&p, "/nix/store/");
    assert!(paths.contains("/nix/store/abc-cc"), "{paths:?}");
    assert!(paths.contains("/nix/store/def-y"), "{paths:?}");
}

struct Fake;

impl Resolve for Fake {
    type Error = String;
    fn target_traits(&self) -> &TargetTraits {
        TargetTraits::NONE
    }
    fn reference(&self, r: &Reference) -> Result<String, String> {
        Ok(match r {
            Reference::Src(s) => format!("/nix/store/src-app/{}", s.rel),
            Reference::CrateSrc(s) => {
                format!(
                    "/nix/store/crate-{}/{}",
                    s.crate_src.rsplit('#').next().unwrap(),
                    s.rel
                )
            }
            Reference::Out(o) => match &o.file {
                Some(f) => format!("/nix/store/{}-{}/{f}", o.out, o.output),
                None => format!("/nix/store/{}-{}", o.out, o.output),
            },
        })
    }
    fn flags(&self, run: &UnitId) -> Result<String, String> {
        Ok(format!("/nix/store/{run}-flags"))
    }
    fn remap_name(&self, base: &Reference) -> Result<String, String> {
        Ok(match base {
            Reference::Src(s) => format!("/src/{}", s.src.rsplit('/').next().unwrap()),
            Reference::CrateSrc(s) => {
                format!("/crates/{}", s.crate_src.rsplit('#').next().unwrap())
            }
            Reference::Out(o) => format!("/out/{}", o.out),
        })
    }
}

/// A resolver with every configuration hook set.
struct Configured;

impl Resolve for Configured {
    type Error = String;
    fn target_traits(&self) -> &TargetTraits {
        TargetTraits::NONE
    }
    fn reference(&self, r: &Reference) -> Result<String, String> {
        Fake.reference(r)
    }
    fn flags(&self, run: &UnitId) -> Result<String, String> {
        Fake.flags(run)
    }
    fn remap_name(&self, base: &Reference) -> Result<String, String> {
        Fake.remap_name(base)
    }
    fn remap_scope(&self, _: &UnitId, _: &CompileUnit) -> Option<String> {
        Some("macro,diagnostics".into())
    }
    fn env_capture(&self, id: &UnitId, _: &Unit) -> Result<Option<String>, String> {
        Ok(Some(format!("/nix/store/capture-{id}/env.json")))
    }
    fn env_overlay(&self, _: &UnitId, unit: &Unit) -> Result<BTreeMap<String, String>, String> {
        let mut m = BTreeMap::from([("SPEC".to_owned(), "1".to_owned())]);
        if let Unit::Compile(_) = unit {
            m.insert("CARGO_PKG_NAME".into(), "overridden".into());
        }
        Ok(m)
    }
    fn strict_sources(&self, _: &UnitId, _: &RunUnit) -> bool {
        true
    }
}

#[test]
fn render_configuration_hooks() {
    let mut p = example();
    // The run's own OUT_DIR is dropped: breakbulk-unit sets it.
    run(&mut p, "r-ring").env.insert(
        "OUT_DIR".into(),
        Text::Concat(vec![Piece::Ref(Reference::Out(OutRef {
            out: "r-ring".into(),
            output: "out".into(),
            file: None,
        }))]),
    );
    let RenderedUnit::Compile(c) = render_unit(&p, &"c-ring".into(), &Configured).unwrap() else {
        panic!()
    };
    assert_eq!(c.env["CARGO_PKG_NAME"], "overridden");
    assert_eq!(c.env["SPEC"], "1");
    assert_eq!(
        c.env_capture.as_deref(),
        Some("/nix/store/capture-c-ring/env.json")
    );
    assert_eq!(c.remap_scope.as_deref(), Some("macro,diagnostics"));
    assert_eq!(
        c.remap,
        [
            (
                "/nix/store/crate-ring@0.17.14".to_owned(),
                "/crates/ring@0.17.14".to_owned()
            ),
            ("/nix/store/r-ring-out".to_owned(), "/out/r-ring".to_owned()),
        ]
    );
    assert_eq!(c.deps, ["/nix/store/c-cfgif-rmeta/libcfg_if-1.rmeta"]);

    let RenderedUnit::Run(r) = render_unit(&p, &"r-ring".into(), &Configured).unwrap() else {
        panic!()
    };
    assert!(r.strict_sources);
    assert!(!r.env.contains_key("OUT_DIR"));
    assert_eq!(r.env["SPEC"], "1");

    // With Cargo's trim-paths, breakbulk adds no remaps.
    p.trim_paths = true;
    let RenderedUnit::Compile(c) = render_unit(&p, &"c-ring".into(), &Configured).unwrap() else {
        panic!()
    };
    assert!(c.remap.is_empty());
    assert_eq!(c.remap_scope, None);

    // When breakbulk turned trim-paths on, Cargo's remaps stay and the scope
    // is breakbulk's, per product kind.
    p.trim_paths_default = true;
    let RenderedUnit::Compile(c) = render_unit(&p, &"c-ring".into(), &Configured).unwrap() else {
        panic!()
    };
    assert!(c.remap.is_empty());
    assert_eq!(c.remap_scope.as_deref(), Some("macro,diagnostics"));
}

/// Decision 121: a run's C prefix maps under Cargo's trim-paths use Cargo's
/// names (`CARGO_TRIM_PATHS_REMAP`'s pairs and the expanded build-directory
/// pair), so they agree with cc-rs's; without trim-paths, breakbulk's own.
#[test]
fn run_prefix_maps_follow_cargo_under_trim_paths() {
    let mut p = example();
    let own = |p: &Plan| {
        let RenderedUnit::Run(r) = render_unit(p, &"r-ring".into(), &Fake).unwrap() else {
            panic!()
        };
        (r.remap, r.out_dir_remap)
    };
    let (remap, out) = own(&p);
    assert_eq!(out.as_deref(), Some("/out/r-ring"));
    assert!(
        remap.iter().all(|(_, to)| !to.starts_with("/cargo/")),
        "{remap:?}"
    );

    p.trim_paths = true;
    let up = "r-up".to_owned();
    p.units.insert(up.clone(), p.units["r-ring"].clone());
    let r = run(&mut p, "r-ring");
    r.env.insert(
        "CARGO_TRIM_PATHS_REMAP".into(),
        Text::Concat(vec![
            Piece::Ref(Reference::CrateSrc(CrateSrcRef {
                crate_src: RING.into(),
                rel: String::new(),
            })),
            Piece::Literal(
                "=/cargo/deps/ring-0.17.14:/nix/store/rust/lib/rustlib/src/rust=/rustc/abc".into(),
            ),
        ]),
    );
    r.build_dir_remap = BTreeMap::from([
        (
            "r-ring".into(),
            "/cargo/build-dir/t/debug/build/ring-1/out".into(),
        ),
        (up, "/cargo/build-dir/t/debug/build/up-2/out".into()),
    ]);
    let (remap, out) = own(&p);
    assert_eq!(
        out.as_deref(),
        Some("/cargo/build-dir/t/debug/build/ring-1/out")
    );
    assert_eq!(
        remap,
        [
            (
                "/nix/store/crate-ring@0.17.14/".to_owned(),
                "/cargo/deps/ring-0.17.14".to_owned()
            ),
            (
                "/nix/store/r-up-out".to_owned(),
                "/cargo/build-dir/t/debug/build/up-2/out".to_owned()
            ),
            (
                "/nix/store/rust/lib/rustlib/src/rust".to_owned(),
                "/rustc/abc".to_owned()
            ),
        ]
    );
}

/// A resolver keeping source paths (`sourcePaths = "keep"`).
struct Keep;

impl Resolve for Keep {
    type Error = String;
    fn target_traits(&self) -> &TargetTraits {
        TargetTraits::NONE
    }
    fn reference(&self, r: &Reference) -> Result<String, String> {
        Fake.reference(r)
    }
    fn flags(&self, run: &UnitId) -> Result<String, String> {
        Fake.flags(run)
    }
    fn remap_name(&self, base: &Reference) -> Result<String, String> {
        Fake.remap_name(base)
    }
    fn remap_scope(&self, _: &UnitId, _: &CompileUnit) -> Option<String> {
        Some("macro,diagnostics".into())
    }
    fn keep_source_paths(&self) -> bool {
        true
    }
}

/// `sourcePaths = "keep"`: no remap, scope or C prefix map from breakbulk,
/// with or without trim-paths.
#[test]
fn keep_source_paths_adds_no_remaps() {
    let mut p = example();
    for trim in [false, true] {
        p.trim_paths = trim;
        let RenderedUnit::Compile(c) = render_unit(&p, &"c-ring".into(), &Keep).unwrap() else {
            panic!()
        };
        assert!(c.remap.is_empty());
        assert_eq!(c.remap_scope, None);
        let RenderedUnit::Run(r) = render_unit(&p, &"r-ring".into(), &Keep).unwrap() else {
            panic!()
        };
        assert!(r.remap.is_empty());
        assert_eq!(r.out_dir_remap, None);
    }
}

/// A chain lib -> mid -> leaf, plus a proc macro with its own dependency.
fn dep_graph() -> Plan {
    let mut p = example();
    let lib = |name: &str, deps: &[(&str, &str)], types: &[&str]| {
        let mut c = match &p.units["c-cfgif"] {
            Unit::Compile(c) => c.clone(),
            _ => unreachable!(),
        };
        c.krate.name = name.into();
        c.krate.types = types.iter().map(|t| t.to_string()).collect();
        c.outputs = if types == ["proc-macro"] {
            BTreeMap::from([("rlib".into(), BTreeSet::from([format!("lib{name}-1.so")]))])
        } else {
            BTreeMap::from([
                (
                    "rmeta".into(),
                    BTreeSet::from([format!("lib{name}-1.rmeta")]),
                ),
                ("rlib".into(), BTreeSet::from([format!("lib{name}-1.rlib")])),
            ])
        };
        c.args = deps
            .iter()
            .map(|(d, output)| {
                let ext = if *output == "rlib" && d.starts_with("pm") {
                    "so"
                } else {
                    output
                };
                Arg::Concat(vec![
                    Piece::Literal(format!("{d}=")),
                    Piece::Ref(Reference::Out(OutRef {
                        out: format!("c-{d}"),
                        output: (*output).into(),
                        file: Some(format!("lib{d}-1.{ext}")),
                    })),
                ])
            })
            .collect();
        Unit::Compile(c)
    };
    let units = [
        ("c-leaf", lib("leaf", &[], &["lib"])),
        ("c-pmdep", lib("pmdep", &[], &["lib"])),
        ("c-pm", lib("pm", &[("pmdep", "rlib")], &["proc-macro"])),
        (
            "c-mid",
            lib("mid", &[("leaf", "rmeta"), ("pm", "rlib")], &["lib"]),
        ),
        ("c-top", lib("top", &[("mid", "rmeta")], &["lib"])),
        ("c-bin", lib("bin", &[("top", "rlib")], &["bin"])),
    ];
    for (id, u) in units {
        p.units.insert(id.into(), u);
    }
    p
}

#[test]
fn transitive_crate_deps() {
    let p = dep_graph();
    let files = |id: &str| -> Vec<String> {
        crate_deps(&p, &id.into())
            .into_iter()
            .map(|o| o.file.unwrap())
            .collect()
    };
    // A library compile needs metadata only; the proc macro's own
    // dependency is not followed.
    assert_eq!(
        files("c-top"),
        ["libleaf-1.rmeta", "libmid-1.rmeta", "libpm-1.so"]
    );
    // A link needs every rlib.
    assert_eq!(
        files("c-bin"),
        [
            "libleaf-1.rlib",
            "libmid-1.rlib",
            "libpm-1.so",
            "libtop-1.rlib"
        ]
    );
    assert!(files("c-leaf").is_empty());
    // The rendered unit carries them as paths.
    let RenderedUnit::Compile(c) = render_unit(&p, &"c-bin".into(), &Fake).unwrap() else {
        panic!()
    };
    assert_eq!(c.deps[0], "/nix/store/c-leaf-rlib/libleaf-1.rlib");
    assert_eq!(c.deps.len(), 4);
}

/// A resolver that marks weak references.
struct Weak;

impl Resolve for Weak {
    type Error = String;
    fn target_traits(&self) -> &TargetTraits {
        TargetTraits::NONE
    }
    fn reference(&self, r: &Reference) -> Result<String, String> {
        Fake.reference(r)
    }
    fn flags(&self, run: &UnitId) -> Result<String, String> {
        Fake.flags(run)
    }
    fn weak_flags(&self, run: &UnitId) -> Result<String, String> {
        Ok(format!("weak:{}", Fake.flags(run)?))
    }
    fn remap_name(&self, base: &Reference) -> Result<String, String> {
        Fake.remap_name(base)
    }
}

/// The breadth-first search `crate_deps` was before it was memoized, as a
/// reference.
fn naive_crate_deps(plan: &Plan, id: &UnitId, want: Option<&str>) -> BTreeSet<OutRef> {
    use crate::deps::{direct_crate_refs, is_proc_macro};
    let Some(Unit::Compile(c)) = plan.units.get(id) else {
        panic!("{id} is not a compile unit of the plan");
    };
    let want = want.unwrap_or(if is_linking(c) { "rlib" } else { "rmeta" });
    let mut out: BTreeSet<OutRef> = BTreeSet::new();
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    let mut queue: std::collections::VecDeque<&str> = Default::default();
    for o in direct_crate_refs(plan, c) {
        out.insert(o.clone());
        if seen.insert(&o.out) {
            queue.push_back(&o.out);
        }
    }
    while let Some(dep) = queue.pop_front() {
        let Some(Unit::Compile(d)) = plan.units.get(dep) else {
            continue;
        };
        if is_proc_macro(d) {
            continue;
        }
        for o in direct_crate_refs(plan, d) {
            let Some(Unit::Compile(e)) = plan.units.get(&o.out) else {
                continue;
            };
            let chosen = match e.outputs.get(want) {
                Some(files) if files.len() == 1 && !is_proc_macro(e) => OutRef {
                    out: o.out.clone(),
                    output: want.to_owned(),
                    file: files.iter().next().cloned(),
                },
                _ => o.clone(),
            };
            out.insert(chosen);
            if seen.insert(&o.out) {
                queue.push_back(&o.out);
            }
        }
    }
    out
}

fn compile_unit<'a>(p: &'a Plan, id: &str) -> &'a CompileUnit {
    match &p.units[id] {
        Unit::Compile(c) => c,
        Unit::Run(_) => panic!("{id} is a run"),
    }
}

/// Every compile unit's dependency directory, built the way
/// `breakbulk-unit` builds it from the rendered units and the manifests their
/// `rmeta` outputs would hold, equals [`crate_deps`]; and every run a unit
/// reaches only weakly is named by a manifest below it. Returns the number
/// of weak references.
pub(crate) fn check_manifests(p: &Plan) -> Result<usize, String> {
    use breakbulk_unit::manifest::{Below, Manifest};
    use breakbulk_unit::spec::SpliceKind;
    let graph = Graph::new(p);
    let rendered: BTreeMap<&UnitId, _> = p
        .units
        .iter()
        .filter(|(_, u)| matches!(u, Unit::Compile(_)))
        .map(|(id, _)| match render_unit_in(&graph, id, &Weak).unwrap() {
            RenderedUnit::Compile(c) => (id, c),
            RenderedUnit::Run(_) => unreachable!(),
        })
        .collect();
    let strip = |s: &str| s.strip_prefix("weak:").unwrap_or(s).to_owned();
    // The manifest each rmeta output would hold, by rmeta directory.
    let mut manifests: BTreeMap<String, (Manifest, Below)> = BTreeMap::new();
    let walk = |dirs: &[String], manifests: &BTreeMap<String, (Manifest, Below)>| {
        let mut b = Below::default();
        for d in dirs {
            let (m, below) = &manifests[d];
            b.crates.extend(m.crates.iter().cloned());
            b.crates.extend(below.crates.iter().cloned());
            b.flags.extend(m.flags.iter().cloned());
            b.flags.extend(below.flags.iter().cloned());
        }
        b
    };
    // Units in dependency order: a unit's manifests are those of units
    // whose manifests exist already.
    let mut done: BTreeSet<&UnitId> = BTreeSet::new();
    let mut weak = 0;
    while done.len() < rendered.len() {
        let before = done.len();
        for (id, c) in &rendered {
            if done.contains(id) || !c.dep_manifests.iter().all(|d| manifests.contains_key(d)) {
                continue;
            }
            done.insert(id);
            let below = walk(&c.dep_manifests, &manifests);
            let mut have: BTreeSet<String> = c.deps.iter().cloned().collect();
            if c.link_manifest_crates {
                have.extend(below.crates.iter().cloned());
            }
            let mut reference = naive_crate_deps(p, id, None);
            if graph.crate_deps(id) != reference {
                return Err(format!("{id}: memoized crate_deps differs from the search"));
            }
            // A linking unit over rlibs without metadata also needs every
            // rmeta below.
            if c.link_manifest_crates && is_linking(compile_unit(p, id)) {
                reference.extend(naive_crate_deps(p, id, Some("rmeta")));
            }
            let want: BTreeSet<String> = reference
                .into_iter()
                .map(|o| Fake.reference(&Reference::Out(o)).unwrap())
                .collect();
            if have != want {
                return Err(format!("{id}: deps {have:?}, expected {want:?}"));
            }
            let mut flags: Vec<&str> = c
                .args
                .iter()
                .filter_map(|a| match a {
                    RenderedArg::Splice(s) => Some(s.splice.as_str()),
                    RenderedArg::Literal(_) => None,
                })
                .collect();
            flags.extend(c.env_splices.iter().map(|s| s.splice.as_str()));
            flags.extend(c.dylib_path_from.iter().map(String::as_str));
            for f in flags {
                if let Some(path) = f.strip_prefix("weak:") {
                    weak += 1;
                    if !below.flags.contains(path) {
                        return Err(format!("{id}: weak {path} is in no manifest below"));
                    }
                }
            }
            if let Some(files) = c.outputs.get("rmeta") {
                let dir = Fake
                    .reference(&Reference::Out(OutRef {
                        out: (*id).clone(),
                        output: "rmeta".into(),
                        file: None,
                    }))
                    .unwrap();
                let mut m = Manifest {
                    crates: files.iter().map(|f| format!("{dir}/{f}")).collect(),
                    flags: BTreeSet::new(),
                    deps: c.dep_manifests.iter().cloned().collect(),
                };
                m.crates.extend(c.manifest_crates.iter().cloned());
                for a in &c.args {
                    if let RenderedArg::Splice(s) = a
                        && s.kind == SpliceKind::RustcLinkSearch
                        && !below.flags.contains(&strip(&s.splice))
                    {
                        m.flags.insert(strip(&s.splice));
                    }
                }
                manifests.insert(dir, (m, below));
            }
        }
        if done.len() == before {
            return Err("a unit names a manifest that no unit writes".into());
        }
    }
    Ok(weak)
}

#[test]
fn manifests_reach_what_crate_deps_lists() {
    let mut p = dep_graph();
    // mid has a build script whose search paths reach top and bin; leaf
    // has one too.
    for (pkg, rid) in [("c-mid", "r-mid"), ("c-leaf", "r-leaf")] {
        let mut r = run(&mut example(), "r-ring").clone();
        r.package = format!("pkg-{pkg}");
        p.units.insert(rid.into(), Unit::Run(r));
        compile(&mut p, pkg)
            .args
            .push(Arg::Splice(Splice::search(rid.into(), SearchIn::Out)));
    }
    for id in ["c-mid", "c-top", "c-bin"] {
        compile(&mut p, id).args.push(Arg::Splice(Splice::search(
            "r-leaf".into(),
            SearchIn::Other,
        )));
    }
    for id in ["c-top", "c-bin"] {
        compile(&mut p, id)
            .args
            .push(Arg::Splice(Splice::search("r-mid".into(), SearchIn::Out)));
    }
    // Weak: r-leaf in mid (leaf's manifest names it), r-leaf and r-mid in
    // top (mid's manifest and the one below it). bin links and has no
    // rmeta output, so it reads no manifests and names everything.
    compile(&mut p, "c-bin").outputs =
        BTreeMap::from([("bin".into(), BTreeSet::from(["bin-1".to_owned()]))]);
    assert_eq!(check_manifests(&p), Ok(3));
    // A linking library with an rmeta output (a cdylib that is also an
    // rlib) reads its dependencies' manifests to write its own.
    let mut q = p.clone();
    compile(&mut q, "c-bin").outputs = BTreeMap::from([
        ("bin".into(), BTreeSet::from(["libbin.so".to_owned()])),
        (
            "rmeta".into(),
            BTreeSet::from(["libbin-1.rmeta".to_owned()]),
        ),
        ("rlib".into(), BTreeSet::from(["libbin-1.rlib".to_owned()])),
    ]);
    assert_eq!(check_manifests(&q), Ok(5));
    // Nightly's -Zembed-metadata=no on the libraries: the bin reads the
    // manifests and links every rmeta too.
    let mut n = p.clone();
    for id in ["c-leaf", "c-mid", "c-top"] {
        let c = compile(&mut n, id);
        c.args.push(Arg::Literal("-Z".into()));
        c.args.push(Arg::Literal("embed-metadata=no".into()));
    }
    // Cargo then passes each direct dependency's rmeta as well as its rlib.
    compile(&mut n, "c-bin").args.push(Arg::Concat(vec![
        Piece::Literal("top=".into()),
        Piece::Ref(Reference::Out(OutRef {
            out: "c-top".into(),
            output: "rmeta".into(),
            file: Some("libtop-1.rmeta".into()),
        })),
    ]));
    let RenderedUnit::Compile(bin) = render_unit(&n, &"c-bin".into(), &Weak).unwrap() else {
        panic!()
    };
    assert!(bin.link_manifest_crates);
    assert_eq!(bin.dep_manifests, ["/nix/store/c-top-rmeta"]);
    assert_eq!(check_manifests(&n), Ok(5));
    let RenderedUnit::Compile(top) = render_unit(&p, &"c-top".into(), &Weak).unwrap() else {
        panic!()
    };
    assert_eq!(top.deps, ["/nix/store/c-mid-rmeta/libmid-1.rmeta"]);
    assert_eq!(top.dep_manifests, ["/nix/store/c-mid-rmeta"]);
    assert!(top.link_manifest_crates);
    let splices: Vec<&str> = top
        .args
        .iter()
        .filter_map(|a| match a {
            RenderedArg::Splice(s) => Some(s.splice.as_str()),
            RenderedArg::Literal(_) => None,
        })
        .collect();
    assert_eq!(
        splices,
        [
            "weak:/nix/store/r-leaf-flags",
            "weak:/nix/store/r-mid-flags"
        ]
    );
    // mid names the proc macro directly, so its manifest lists it.
    let RenderedUnit::Compile(mid) = render_unit(&p, &"c-mid".into(), &Weak).unwrap() else {
        panic!()
    };
    assert_eq!(mid.manifest_crates, ["/nix/store/c-pm-rlib/libpm-1.so"]);
    // The bin links: every rlib, no manifests, nothing weak.
    let RenderedUnit::Compile(bin) = render_unit(&p, &"c-bin".into(), &Weak).unwrap() else {
        panic!()
    };
    assert_eq!(bin.deps.len(), 4);
    assert!(bin.dep_manifests.is_empty() && !bin.link_manifest_crates);
    assert!(
        !unit_env_value(&RenderedUnit::Compile(bin))
            .unwrap()
            .contains("weak:")
    );
}

/// [`check_manifests`] over real plans: `BREAKBULK_CHECK_PLANS` is a
/// `:`-separated list of `plan.json` files.
#[test]
fn manifests_on_plans_from_env() {
    let Some(list) = std::env::var_os("BREAKBULK_CHECK_PLANS") else {
        return;
    };
    for path in std::env::split_paths(&list) {
        let p = Plan::from_json(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let weak = check_manifests(&p).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        eprintln!("{}: ok, {weak} weak references", path.display());
    }
}

#[test]
fn render_and_expand() {
    let p = example();
    let unit = render_unit(&p, &"c-ring".into(), &Fake).unwrap();
    let json = unit_env_value(&unit).unwrap();
    assert!(json.starts_with(r#"{"args":["--crate-name","ring","/nix/store/crate-ring@0.17.14/src/lib.rs","--externcfg_if=/nix/store/c-cfgif-rmeta/libcfg_if-1.rmeta",{"kind":"rustc-cfg","splice":"/nix/store/r-ring-flags"}"#), "{json}");
    // breakbulk-unit reads it back.
    let back: RenderedUnit = serde_json::from_str(&json).unwrap();
    assert_eq!(back, unit);
    let RenderedUnit::Compile(c) = back else {
        panic!()
    };
    assert_eq!(c.cwd, "/nix/store/crate-ring@0.17.14/");
    assert_eq!(c.env["OUT_DIR"], "/nix/store/r-ring-out");

    // Expand with a run's directives.
    let d = BuildOutput {
        cfgs: vec!["x".into()],
        library_links: vec!["static=ring_core".into()],
        library_paths: vec![LibraryPath {
            value: "native=/nix/store/r-ring-out".into(),
            in_out_dir: true,
            in_build_dir: true,
        }],
        env: vec![("RING_CORE_PREFIX".into(), "ring_core_".into())],
        ..Default::default()
    };
    let lookup = |f: &str| (f == "/nix/store/r-ring-flags").then_some(&d);
    let argv = breakbulk_unit::splice::expand_args(&c.args, lookup).unwrap();
    assert_eq!(&argv[4..], ["--cfg", "x", "-l", "static=ring_core"]);
    let env = breakbulk_unit::splice::expand_env(&c.env, &c.env_splices, lookup).unwrap();
    assert_eq!(env["RING_CORE_PREFIX"], "ring_core_");
    assert!(matches!(c.args[4], RenderedArg::Splice(_)));

    // Run units render their targets and metadata sources.
    let mut p = example();
    run(&mut p, "r-ring").metadata_from.insert("r-up".into());
    let RenderedUnit::Run(r) = render_unit(&p, &"r-ring".into(), &Fake).unwrap() else {
        panic!()
    };
    assert_eq!(r.metadata_from, ["/nix/store/r-up-flags"]);
    assert_eq!(r.script, "/nix/store/c-ring-build-bin");
    assert_eq!(r.rust_version.as_deref(), Some("1.66"));
    let json = unit_env_value(&RenderedUnit::Run(r.clone())).unwrap();
    assert!(json.starts_with(r#"{"cwd":"#), "{json}");
    assert!(json.contains(r#""kind":"run""#), "{json}");
    assert_eq!(
        serde_json::from_str::<RenderedUnit>(&json).unwrap(),
        RenderedUnit::Run(r)
    );
}

#[test]
fn rendered_unit_rejects_unknown_fields() {
    let p = example();
    let json = unit_env_value(&render_unit(&p, &"c-cfgif".into(), &Fake).unwrap()).unwrap();
    let bad = json.replacen('{', r#"{"bogus":1,"#, 1);
    assert!(serde_json::from_str::<RenderedUnit>(&bad).is_err());
}

#[test]
fn doctests_validate_like_compiles() {
    let mut p = example();
    let mut d = Doctest {
        package: compile(&mut p, "c-ring").package.clone(),
        krate: compile(&mut p, "c-ring").krate.clone(),
        program: vec![Text::Literal("/nix/store/x-rustc/bin/rustdoc".into())],
        args: vec![
            Arg::Literal("--test".into()),
            Arg::SearchPaths(SearchPathsSplice {
                search_paths_of: vec!["r-ring".into()],
                literals: vec!["/ovr/lib".into()],
            }),
            Arg::Splice(Splice::new("r-ring".into(), SpliceKind::RustcCfg)),
        ],
        env: BTreeMap::new(),
        env_splices: vec![],
        dylib_path_from: vec!["r-ring".into()],
        cwd: compile(&mut p, "c-ring").cwd.clone(),
    };
    p.doctests.insert("d-ring".into(), d.clone());
    assert_eq!(errors(&p), Vec::<String>::new());
    let back = Plan::from_json(&p.to_canonical_json()).unwrap();
    let mut normal = p.clone();
    normal.normalize();
    assert_eq!(back, normal);

    d.args.push(Arg::SearchPaths(SearchPathsSplice {
        search_paths_of: vec!["c-cfgif".into()],
        literals: vec!["native=/build/lib".into()],
    }));
    d.args
        .push(Arg::Literal("--test-run-directory=/build/x".into()));
    p.doctests.insert("d-ring".into(), d);
    assert_error(&p, "searchPathsOf names c-cfgif, which is not a run unit");
    assert_error(&p, "forbidden path `/build`");
    assert_error(
        &p,
        "searchPathsOf literal contains the forbidden path `/build`",
    );

    let mut p = example();
    compile(&mut p, "c-ring")
        .args
        .push(Arg::SearchPaths(SearchPathsSplice {
            search_paths_of: vec!["r-ring".into()],
            literals: vec![],
        }));
    assert_error(&p, "a searchPathsOf splice outside a doctest");
}

#[test]
fn debuginfo_side_files() {
    let bin = ["bin".to_owned()];
    let lib = ["lib".to_owned()];
    let staticlib = ["staticlib".to_owned()];
    let msvc = &msvc_traits();
    let other = &elf_traits();
    let wt = |args: &[&str], types: &[String], t: &TargetTraits| {
        writes_debuginfo_side_files(args.iter().map(|a| Some(*a)), types, t)
    };
    let w = |args: &[&str], types: &[String]| wt(args, types, other);
    // msvc (the linker always writes a PDB): one for every linked crate,
    // debuginfo or not. The traits decide, not the `--target` spelling.
    let target = ["--target", "x86_64-pc-windows-msvc"];
    assert!(wt(&[], &bin, msvc));
    assert!(wt(&["-C", "strip=debuginfo"], &bin, msvc));
    assert!(wt(&[], &["cdylib".to_owned()], msvc));
    assert!(wt(&["--test"], &lib, msvc));
    assert!(!wt(&[], &staticlib, msvc));
    assert!(!wt(&[], &lib, msvc));
    assert!(!w(&target, &bin));
    // ELF: only split debuginfo, with debuginfo on.
    let gnu = ["--target", "x86_64-unknown-linux-gnu"];
    assert!(!w(&gnu, &bin));
    assert!(!w(&[&gnu[..], &["-C", "debuginfo=2"]].concat(), &bin));
    assert!(w(
        &[
            &gnu[..],
            &["-C", "debuginfo=2", "-C", "split-debuginfo=packed"]
        ]
        .concat(),
        &bin
    ));
    assert!(w(
        &["-Cdebuginfo=1", "-Csplit-debuginfo=unpacked"],
        &staticlib
    ));
    assert!(!w(
        &["-C", "debuginfo=2", "-C", "split-debuginfo=off"],
        &bin
    ));
    // The last value wins; `-g` after `-C debuginfo` is full debuginfo.
    assert!(!w(
        &[
            "-C",
            "debuginfo=2",
            "-C",
            "split-debuginfo=packed",
            "-C",
            "debuginfo=0"
        ],
        &bin
    ));
    assert!(w(
        &[
            "-C",
            "debuginfo=none",
            "-g",
            "--codegen=split-debuginfo=packed"
        ],
        &bin
    ));
    assert!(!w(
        &["-g", "-C", "debuginfo=none", "-C", "split-debuginfo=packed"],
        &bin
    ));
    assert!(!w(&["-C", "split-debuginfo=packed"], &bin));
    // A non-literal argument is a value, not the next option's name.
    let args = [
        Some("-C"),
        None,
        Some("-C"),
        Some("debuginfo=2"),
        Some("-C"),
        Some("split-debuginfo=packed"),
    ];
    assert!(writes_debuginfo_side_files(args, &bin, other));
    // A target with no debug artifacts (wasm) never, whatever the flags;
    // one with only a packed artifact not for unpacked.
    let split = ["-C", "debuginfo=2", "-C", "split-debuginfo=packed"];
    assert!(!wt(&split, &bin, TargetTraits::NONE));
    let packed_only = TargetTraits {
        debug_artifacts: vec![DebugArtifact {
            suffix: ".dSYM".into(),
            when: DebugArtifactWhen::SplitPacked,
            per_object: false,
            directory: true,
        }],
    };
    assert!(wt(&split, &bin, &packed_only));
    assert!(!wt(
        &["-C", "debuginfo=2", "-C", "split-debuginfo=unpacked"],
        &bin,
        &packed_only
    ));
}

/// The traits' `debugArtifacts` of an ELF target (lib/target-traits.nix).
fn elf_traits() -> TargetTraits {
    serde_json::from_str(
        r#"{"debugArtifacts":[{"suffix":".dwp","when":"split-packed"},{"suffix":".dwo","when":"split-unpacked","perObject":true}]}"#,
    )
    .unwrap()
}

/// The traits' `debugArtifacts` of an msvc target.
fn msvc_traits() -> TargetTraits {
    serde_json::from_str(r#"{"debugArtifacts":[{"suffix":".pdb","when":"always"}]}"#).unwrap()
}

#[test]
fn debug_output_only_where_side_files() {
    let lit = |a: &[&str]| {
        a.iter()
            .map(|s| Arg::Literal((*s).into()))
            .collect::<Vec<_>>()
    };
    let mut p = example();
    // c-app: a target bin with no debuginfo flags.
    let elf = &elf_traits();
    assert!(!compile(&mut p, "c-app").has_debug_output(elf));
    compile(&mut p, "c-app").args.extend(lit(&[
        "-C",
        "debuginfo=2",
        "-C",
        "split-debuginfo=unpacked",
    ]));
    assert!(compile(&mut p, "c-app").has_debug_output(elf));
    // Host units never: their side files are discarded.
    let msvc = &msvc_traits();
    assert!(compile(&mut p, "c-app").has_debug_output(msvc));
    let c = compile(&mut p, "c-ring-build");
    assert!(!c.has_debug_output(msvc));
    // Libraries never.
    let c = compile(&mut p, "c-cfgif");
    assert!(!c.has_debug_output(msvc));
}
