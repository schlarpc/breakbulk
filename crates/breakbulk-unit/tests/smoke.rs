//! End-to-end smoke test of `breakbulk-unit` outside Nix.
//!
//! `tests/unit-smoke/plan.json` is a hand-written plan for the fixture in
//! `tests/unit-smoke/fixture`: a library whose build script compiles a C
//! file with `$CC` and emits `rustc-cfg`, `rustc-check-cfg`, `rustc-env`,
//! `rustc-link-search` and `rustc-link-lib`, and a binary depending on it. Its arguments are those of `cargo build -vv
//! --target x86_64-unknown-linux-gnu` (Cargo 1.99) with the target-directory
//! arguments removed, as the planner would write them.
//!
//! The test renders every unit with `breakbulk-format`, using tokens for
//! every path (`@bb:out:<unit>:<output>@`, `@bb:src@`, `@bb:rustc@`,
//! `@bb:capture@`), and checks the result against
//! `tests/unit-smoke/units.json`, which `tests/unit-smoke/default.nix` turns
//! into real derivations. (Set `BREAKBULK_BLESS=1` to rewrite it.) It then
//! replaces the tokens with directories in a temporary "store", runs
//! `breakbulk-unit unit` for each unit in dependency order with a cleared
//! environment, as Nix would, and runs the resulting binary.
//!
//! The env capture here is the test's own `PATH`, `CC`, `AR` and nixpkgs'
//! compiler-wrapper role variables. In a `nix develop` shell those make `cc`
//! the nixpkgs wrapper, which applies the unit's `NIX_CFLAGS_COMPILE`, so the
//! test also checks that C objects carry no source path. Elsewhere that part
//! is skipped with a note.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

use breakbulk_format::rendered::derivation_output;
use breakbulk_format::{
    CompileUnit, Plan, Reference, Resolve, Unit, UnitId, ValidationOptions, render_unit,
    unit_env_value, validate,
};
use serde::Serialize;

const BB_SRC: &str = "@bb:src@";
const BB_RUSTC: &str = "@bb:rustc@";
const BB_CAPTURE: &str = "@bb:capture@";

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// A reference a rendered unit makes, by token.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(untagged)]
enum Ref {
    Out {
        token: String,
        unit: String,
        output: String,
    },
    Special {
        token: String,
        special: String,
    },
}

impl Ref {
    fn token(&self) -> &str {
        match self {
            Ref::Out { token, .. } | Ref::Special { token, .. } => token,
        }
    }
}

struct Tokens<'a> {
    plan: &'a Plan,
    refs: RefCell<BTreeSet<Ref>>,
}

impl Tokens<'_> {
    fn out(&self, unit: &str, output: &str) -> String {
        let token = format!("@bb:out:{unit}:{output}@");
        self.refs.borrow_mut().insert(Ref::Out {
            token: token.clone(),
            unit: unit.into(),
            output: output.into(),
        });
        token
    }
}

impl Resolve for Tokens<'_> {
    type Error = String;
    fn target_traits(&self) -> &breakbulk_format::TargetTraits {
        breakbulk_format::TargetTraits::NONE
    }
    fn reference(&self, r: &Reference) -> Result<String, String> {
        Ok(match r {
            Reference::Src(s) if s.rel.is_empty() => BB_SRC.to_owned(),
            Reference::Src(s) => format!("{BB_SRC}/{}", s.rel),
            Reference::CrateSrc(s) => return Err(format!("no crate sources here: {s:?}")),
            Reference::Out(o) => {
                let output = match &self.plan.units[&o.out] {
                    Unit::Run(_) => "out",
                    Unit::Compile(_) => derivation_output(&o.output),
                };
                let base = self.out(&o.out, output);
                match &o.file {
                    Some(f) => format!("{base}/{f}"),
                    None => base,
                }
            }
        })
    }
    fn flags(&self, run: &UnitId) -> Result<String, String> {
        Ok(self.out(run, "flags"))
    }
    fn remap_name(&self, base: &Reference) -> Result<String, String> {
        Ok(match base {
            // Workspace members are relative to the workspace root, as with
            // Cargo's trim-paths.
            Reference::Src(_) => ".".into(),
            Reference::Out(o) => format!("/breakbulk/build/{}", o.out),
            Reference::CrateSrc(_) => unreachable!(),
        })
    }
    fn remap_scope(&self, _: &UnitId, _: &CompileUnit) -> Option<String> {
        None
    }
    fn env_capture(&self, _: &UnitId, _: &Unit) -> Result<Option<String>, String> {
        Ok(Some(BB_CAPTURE.into()))
    }
}

#[derive(Serialize)]
struct UnitDrv {
    /// The derivation's outputs.
    outputs: Vec<String>,
    /// Every token in `unit`, with what it stands for.
    refs: Vec<Ref>,
    /// `BREAKBULK_UNIT`, with tokens.
    unit: String,
}

fn derivation_outputs(u: &Unit) -> Vec<String> {
    match u {
        Unit::Compile(c) => c
            .outputs
            .keys()
            .map(|o| derivation_output(o).to_owned())
            .chain(
                c.has_debug_output(breakbulk_format::TargetTraits::NONE)
                    .then(|| "debug".to_owned()),
            )
            .collect(),
        Unit::Run(_) => vec!["flags".into(), "out".into()],
    }
}

fn render(plan: &Plan) -> BTreeMap<String, UnitDrv> {
    plan.units
        .iter()
        .map(|(id, u)| {
            let t = Tokens {
                plan,
                refs: RefCell::default(),
            };
            let unit = unit_env_value(&render_unit(plan, id, &t).unwrap()).unwrap();
            let mut refs = t.refs.into_inner();
            for (token, special) in [
                (BB_SRC, "src"),
                (BB_RUSTC, "rustc"),
                (BB_CAPTURE, "capture"),
            ] {
                if unit.contains(token) {
                    refs.insert(Ref::Special {
                        token: token.into(),
                        special: special.into(),
                    });
                }
            }
            let drv = UnitDrv {
                outputs: derivation_outputs(u),
                refs: refs.into_iter().collect(),
                unit,
            };
            (id.clone(), drv)
        })
        .collect()
}

/// Units in dependency order.
fn topo_order(units: &BTreeMap<String, UnitDrv>) -> Vec<String> {
    let mut done: Vec<String> = Vec::new();
    while done.len() < units.len() {
        let before = done.len();
        for (id, u) in units {
            if done.contains(id) {
                continue;
            }
            let ready = u.refs.iter().all(|r| match r {
                Ref::Out { unit, .. } => done.contains(unit),
                Ref::Special { .. } => true,
            });
            if ready {
                done.push(id.clone());
            }
        }
        assert!(done.len() > before, "cycle among units");
    }
    done
}

fn which(prog: &str) -> PathBuf {
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|d| d.join(prog))
        .find(|p| p.is_file())
        .unwrap_or_else(|| panic!("`{prog}` is not on PATH"))
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let dst = to.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            copy_dir(&e.path(), &dst);
        } else {
            std::fs::copy(e.path(), &dst).unwrap();
        }
    }
}

fn contains(haystack: &[u8], needle: &str) -> bool {
    haystack
        .windows(needle.len())
        .any(|w| w == needle.as_bytes())
}

#[test]
fn smoke() {
    let dir = repo().join("tests/unit-smoke");
    let plan = Plan::from_json(&std::fs::read_to_string(dir.join("plan.json")).unwrap()).unwrap();
    validate(
        &plan,
        &ValidationOptions {
            forbidden_paths: vec!["/build".into(), "/homeless-shelter".into()],
        },
    )
    .unwrap();

    // The rendered units, as default.nix reads them.
    let units = render(&plan);
    let mut json = serde_json::to_string_pretty(&units).unwrap();
    json.push('\n');
    let golden = dir.join("units.json");
    if std::env::var_os("BREAKBULK_BLESS").is_some() {
        std::fs::write(&golden, &json).unwrap();
    } else {
        assert_eq!(
            std::fs::read_to_string(&golden).unwrap_or_default(),
            json,
            "tests/unit-smoke/units.json is out of date; rerun with BREAKBULK_BLESS=1"
        );
    }

    if !cfg!(all(target_arch = "x86_64", target_os = "linux")) {
        eprintln!("the smoke plan targets x86_64-unknown-linux-gnu; not running it here");
        return;
    }

    // A fake store: one directory per derivation output.
    let tmp = std::env::temp_dir().join(format!("breakbulk-unit-smoke-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    let store = tmp.join("store");
    std::fs::create_dir_all(&store).unwrap();
    let src = store.join("source");
    copy_dir(&dir.join("fixture"), &src);
    let capture = store.join("capture-env.json");
    let capture_env: BTreeMap<String, String> = std::env::vars()
        .filter(|(k, _)| {
            matches!(k.as_str(), "PATH" | "CC" | "AR")
                || (k.starts_with("NIX_") && k.contains("_WRAPPER_TARGET_HOST_"))
        })
        .collect();
    let wrapped = capture_env
        .keys()
        .any(|k| k.starts_with("NIX_CC_WRAPPER_TARGET_HOST_"));
    std::fs::write(&capture, serde_json::to_string(&capture_env).unwrap()).unwrap();
    let rustc = which("rustc");
    let out_path = |unit: &str, output: &str| store.join(format!("{unit}-{output}"));

    for id in topo_order(&units) {
        let u = &units[&id];
        let mut text = u.unit.clone();
        for r in &u.refs {
            let path = match r {
                Ref::Out { unit, output, .. } => out_path(unit, output),
                Ref::Special { special, .. } => match special.as_str() {
                    "src" => src.clone(),
                    "rustc" => rustc.clone(),
                    "capture" => capture.clone(),
                    s => panic!("unknown special {s}"),
                },
            };
            text = text.replace(r.token(), &path.display().to_string());
        }
        assert!(!text.contains("@bb:"), "{id}: unreplaced token in {text}");
        let build = tmp.join(format!("build-{id}"));
        std::fs::create_dir_all(&build).unwrap();
        let status = Command::new(env!("CARGO_BIN_EXE_breakbulk-unit"))
            .arg("unit")
            .env_clear()
            .env("BREAKBULK_UNIT", &text)
            .env("TMPDIR", &build)
            .env("NIX_BUILD_CORES", "2")
            .env("PATH", "/nonexistent-outer-path")
            .envs(u.outputs.iter().map(|o| (o, out_path(&id, o))))
            .status()
            .unwrap();
        assert!(status.success(), "unit {id} failed: {status}");
        for o in &u.outputs {
            assert!(out_path(&id, o).is_dir(), "{id} did not create output {o}");
        }
    }

    // The build script's directives were recorded and spliced.
    let run = "r-smokelib-63aa584f9c6a6c6c";
    let d = breakbulk_unit::read_directives(&out_path(run, "flags")).unwrap();
    assert_eq!(d.cfgs, ["smoke_cfg"]);
    assert_eq!(d.env, [("SMOKE_ENV".into(), "hello-from-build".into())]);
    assert!(d.library_paths[0].in_out_dir, "{:?}", d.library_paths);
    assert!(out_path(run, "out").join("gen.rs").is_file());
    assert!(
        out_path("c-a0e9aa7440d71279", "rmeta")
            .join("libsmokelib-87e5d8c802f76f4a.rmeta")
            .is_file()
    );

    // The binary runs.
    let app = out_path("c-a6654c0a89d81026", "out").join("smokeapp-b0ba845afe70cf35");
    let output = Command::new(&app).output().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "smoke ok: hello-from-build 42 c=6\n"
    );

    // The build script's C compiler got the unit's seed (its plan key) and a
    // prefix map for the source and OUT_DIR.
    let run_out = out_path(run, "out");
    let cflags = std::fs::read_to_string(run_out.join("nix-cflags-compile.txt")).unwrap();
    assert!(
        cflags.starts_with(&format!(" -frandom-seed={run} ")),
        "{cflags}"
    );
    for map in [
        format!("-ffile-prefix-map={}=.", src.display()),
        format!(
            "-ffile-prefix-map={}=/breakbulk/build/{run}",
            run_out.display()
        ),
    ] {
        assert!(cflags.contains(&map), "{map} not in {cflags}");
    }

    // Remapping kept the source and OUT_DIR paths out of the library and the
    // binary (every scope is remapped here). The rlib bundles the C archive,
    // and the binary links it: their C debug info is remapped only through
    // the nixpkgs compiler wrapper.
    let archive = run_out.join("native/libsmokec.a");
    let mut checked =
        vec![out_path("c-a0e9aa7440d71279", "rmeta").join("libsmokelib-87e5d8c802f76f4a.rmeta")];
    if wrapped {
        checked.extend([
            app.clone(),
            out_path("c-a0e9aa7440d71279", "rlib").join("libsmokelib-87e5d8c802f76f4a.rlib"),
            archive.clone(),
        ]);
        // The C debug info names the source by its remapped path.
        let bytes = std::fs::read(&archive).unwrap();
        assert!(
            contains(&bytes, "./smokelib/csrc/smoke.c"),
            "{} has no remapped source name",
            archive.display()
        );
    } else {
        eprintln!(
            "note: `cc` is not the nixpkgs compiler wrapper here; not checking C objects for source paths"
        );
    }
    for f in checked {
        let bytes = std::fs::read(&f).unwrap();
        for p in [&src, &out_path(run, "out")] {
            assert!(
                !contains(&bytes, &p.display().to_string()),
                "{} contains {}",
                f.display(),
                p.display()
            );
        }
    }

    let _ = std::fs::remove_dir_all(&tmp);
}
