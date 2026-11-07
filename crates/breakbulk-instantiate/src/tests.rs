use std::collections::BTreeMap;

use breakbulk_format::rendered::{RenderedUnit, derivation_output, package_name_version};
use breakbulk_format::{
    CompileUnit, Plan, Reference, Resolve, RootKind, RunUnit, Unit, UnitId, render_unit,
    unit_env_value,
};

use super::inputs::*;
use super::output::*;
use super::*;

const RUSTC: &str = "/nix/store/00000000000000000000000000000000-rustc-1.99.0";
const UNIT: &str = "/nix/store/11111111111111111111111111111111-breakbulk-unit/bin/breakbulk-unit";
const SHELL: &str = "/nix/store/22222222222222222222222222222222-bash/bin/bash";
const APP: &str = "c-a6654c0a89d81026";
const LIB: &str = "c-a0e9aa7440d71279";
const SCRIPT: &str = "c-138fecd4c9176bd0";
const RUN: &str = "r-smokelib-63aa584f9c6a6c6c";

/// The unit-smoke plan, with its rustc token replaced by a store path.
fn smoke_plan() -> Plan {
    let text = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/unit-smoke/plan.json"),
    )
    .unwrap()
    .replace("@bb:rustc@", &format!("{RUSTC}/bin/rustc"));
    Plan::from_json(&text).unwrap()
}

fn smoke_inputs() -> Inputs {
    Inputs {
        plan: smoke_plan(),
        sources: Sources {
            workspace: ["smokelib".into(), "smokeapp".into()].into(),
            crates: Default::default(),
        },
        toolchains: Toolchains {
            system: "x86_64-linux".into(),
            store_dir: "/nix/store".into(),
            tools: BTreeMap::from([
                ("rustc".into(), RUSTC.into()),
                (TOOL_UNIT.into(), UNIT.into()),
                (TOOL_SHELL.into(), SHELL.into()),
            ]),
            host: PlatformSpec {
                env: ["HOST_ONLY".into()].into(),
                env_capture: true,
            },
            target: PlatformSpec {
                env: ["CFLAGS".into(), "SHARED".into()].into(),
                env_capture: true,
            },
            shipped_remap_scope: None,
        },
        overrides: Overrides {
            strict_sources: false,
            packages: BTreeMap::from([
                (
                    "smokelib".into(),
                    PackageOverride {
                        target: PlatformSpec {
                            env: ["SHARED".into(), "LIB_ONLY".into()].into(),
                            env_capture: true,
                        },
                        strict_sources: Some(true),
                        ..Default::default()
                    },
                ),
                (
                    // Matches nothing: smokeapp is 0.1.0.
                    "smokeapp@9.9.9".into(),
                    PackageOverride {
                        target: PlatformSpec {
                            env: ["NEVER".into()].into(),
                            env_capture: true,
                        },
                        ..Default::default()
                    },
                ),
            ]),
        },
        roots: None,
    }
}

/// What the Nix side substitutes for each input key in these tests.
fn input_value(key: &str) -> String {
    match key {
        "src:smokelib" => "/nix/store/33333333333333333333333333333333-source".into(),
        "src:smokeapp" => "/nix/store/44444444444444444444444444444444-source".into(),
        "tool:rustc" => RUSTC.into(),
        "tool:breakbulk-unit" => UNIT.into(),
        "tool:shell" => SHELL.into(),
        k if k.starts_with("capture:") || k.contains(":capture:") => {
            format!(
                "/nix/store/55555555555555555555555555555555-{}",
                k.replace(':', "-")
            )
        }
        // Empty values, for list-like variables.
        k if k.ends_with(":EMPTY") || k.ends_with(":PATH") && k.starts_with("env:") => {
            String::new()
        }
        // Env values that need escaping.
        k => format!("value of {k}: \"quoted\" \\ back\nnew line\u{1} é"),
    }
}

fn unit_path(unit: &str, output: &str) -> String {
    format!("/nix/store/66666666666666666666666666666666-{unit}-{output}")
}

/// What the Nix side does with `parts`.
fn resolve(parts: &[Part]) -> String {
    parts
        .iter()
        .map(|p| match p {
            Part::Literal(s) => s.clone(),
            Part::Unit { unit, output, .. } => unit_path(unit, output),
            Part::Input { input, json } => {
                let v = input_value(input);
                if *json {
                    let q = serde_json::to_string(&v).unwrap();
                    q[1..q.len() - 1].to_owned()
                } else {
                    v
                }
            }
            Part::Join { join, sep } => join
                .iter()
                .map(|item| resolve(item))
                .filter(|v| !v.is_empty())
                .collect::<Vec<_>>()
                .join(sep),
        })
        .collect()
}

fn attr(d: &Drv, name: &str) -> String {
    match &d.attrs[name] {
        Value::String(s) => s.clone(),
        Value::Parts { parts } => resolve(parts),
        Value::Strings(s) => panic!("{name} is a list: {s:?}"),
    }
}

/// Rendering with the real paths directly, as dynamic-derivation mode will.
struct RealPaths<'a>(&'a Inputs);

impl RealPaths<'_> {
    fn ov(&self, id: &str) -> Option<(String, &PackageOverride)> {
        let (n, v) = package_name_version(id)?;
        [format!("{n}@{v}"), n.to_owned()]
            .into_iter()
            .find_map(|k| self.0.overrides.packages.get(&k).map(|o| (k, o)))
    }
}

impl Resolve for RealPaths<'_> {
    type Error = String;
    fn reference(&self, r: &Reference) -> Result<String, String> {
        let (base, rel) = match r {
            Reference::Src(s) => (
                input_value(&keys::src(workspace_dir(&self.0.plan, &s.src).unwrap())),
                s.rel.as_str(),
            ),
            Reference::CrateSrc(s) => (input_value(&keys::crate_src(&s.crate_src)), s.rel.as_str()),
            Reference::Out(o) => {
                let output = match &self.0.plan.units[&o.out] {
                    Unit::Run(_) => "out",
                    Unit::Compile(_) => derivation_output(&o.output),
                };
                (unit_path(&o.out, output), o.file.as_deref().unwrap_or(""))
            }
        };
        Ok(if rel.is_empty() {
            base
        } else {
            format!("{base}/{rel}")
        })
    }
    fn flags(&self, run: &UnitId) -> Result<String, String> {
        Ok(unit_path(run, "flags"))
    }
    fn remap_name(&self, base: &Reference) -> Result<String, String> {
        Ok(match base {
            Reference::Src(_) => ".".into(),
            Reference::CrateSrc(s) => {
                let (n, v) = package_name_version(&s.crate_src).unwrap();
                format!("{n}-{v}")
            }
            Reference::Out(o) => format!("/breakbulk/build/{}", o.out),
        })
    }
    fn remap_scope(&self, _: &UnitId, c: &CompileUnit) -> Option<String> {
        let scope = self.0.toolchains.shipped_remap_scope.as_ref()?;
        let test = c
            .args
            .iter()
            .any(|a| matches!(a, breakbulk_format::Arg::Literal(s) if s == "--test"));
        let scope = match c.platform {
            breakbulk_format::Platform::Target => scope.clone(),
            breakbulk_format::Platform::Host => scope.replace(",coverage", ""),
        };
        (!test && has_remap_scope(&self.0.plan.rustc)).then_some(scope)
    }
    fn env_capture(&self, _: &UnitId, u: &Unit) -> Result<Option<String>, String> {
        let p = platform(u);
        if let Some((k, o)) = self.ov(u.package())
            && o.platform(p).env_capture
        {
            return Ok(Some(input_value(&keys::override_capture(&k, p))));
        }
        Ok(self
            .0
            .toolchains
            .platform(p)
            .env_capture
            .then(|| input_value(&keys::capture(p))))
    }
    fn env_overlay(&self, _: &UnitId, u: &Unit) -> Result<BTreeMap<String, String>, String> {
        let p = platform(u);
        let mut env: BTreeMap<String, String> = self
            .0
            .toolchains
            .platform(p)
            .env
            .iter()
            .map(|v| (v.clone(), input_value(&keys::env(p, v))))
            .collect();
        if let Some((k, o)) = self.ov(u.package()) {
            let layer = o
                .platform(p)
                .env
                .iter()
                .map(|v| (v.clone(), input_value(&keys::override_env(&k, p, v))))
                .collect();
            breakbulk_format::merge_layer_with(self, &mut env, layer)?;
        }
        Ok(env)
    }
    fn strict_sources(&self, _: &UnitId, run: &RunUnit) -> bool {
        self.ov(&run.package)
            .and_then(|(_, o)| o.strict_sources)
            .unwrap_or(self.0.overrides.strict_sources)
    }
}

#[test]
fn substituted_units_equal_direct_rendering() {
    let inputs = smoke_inputs();
    let out = instantiate(&inputs).unwrap();
    assert_eq!(out.units.len(), 4);
    for (id, d) in &out.units {
        let direct =
            unit_env_value(&render_unit(&inputs.plan, id, &RealPaths(&inputs)).unwrap()).unwrap();
        assert_eq!(attr(d, "BREAKBULK_UNIT"), direct, "unit {id}");
        assert_eq!(attr(d, "builder"), UNIT);
        assert_eq!(d.attrs["args"], Value::Strings(vec!["unit".into()]));
        assert_eq!(attr(d, "system"), "x86_64-linux");
    }
}

#[test]
fn shipped_remap_scope() {
    let scope_of = |inputs: &Inputs| -> BTreeMap<String, Option<String>> {
        let out = instantiate(inputs).unwrap();
        out.units
            .iter()
            .map(|(id, d)| {
                let u: serde_json::Value =
                    serde_json::from_str(&attr(d, "BREAKBULK_UNIT")).unwrap();
                let direct =
                    unit_env_value(&render_unit(&inputs.plan, id, &RealPaths(inputs)).unwrap())
                        .unwrap();
                assert_eq!(attr(d, "BREAKBULK_UNIT"), direct, "unit {id}");
                let scope = u["remapScope"].as_str().map(str::to_owned);
                (id.clone(), scope)
            })
            .collect()
    };
    let mut inputs = smoke_inputs();
    assert!(scope_of(&inputs).values().all(Option::is_none));
    inputs.toolchains.shipped_remap_scope = Some("macro,diagnostics".into());
    let scopes = scope_of(&inputs);
    for id in [APP, LIB, SCRIPT] {
        assert_eq!(scopes[id].as_deref(), Some("macro,diagnostics"), "{id}");
    }
    assert_eq!(scopes[RUN], None);
    // Coverage: host units (the build script) leave the coverage scope out.
    inputs.toolchains.shipped_remap_scope = Some("macro,diagnostics,coverage".into());
    let scopes = scope_of(&inputs);
    for id in [APP, LIB] {
        assert_eq!(
            scopes[id].as_deref(),
            Some("macro,diagnostics,coverage"),
            "{id}"
        );
    }
    assert_eq!(scopes[SCRIPT].as_deref(), Some("macro,diagnostics"));
    // rustc before 1.95 has no --remap-path-scope.
    inputs.plan.rustc = "1.94.1 (e408947bf 2026-01-01)".into();
    assert!(scope_of(&inputs).values().all(Option::is_none));
    assert!(has_remap_scope("1.95.0 (abc 2026-01-01)"));
    assert!(has_remap_scope("1.101.0-nightly (abc 2026-10-01)"));
    assert!(!has_remap_scope("1.94.0"));
    assert!(!has_remap_scope(""));
}

#[test]
fn units_json_names_no_store_path() {
    let json = to_json(&instantiate(&smoke_inputs()).unwrap());
    assert!(!json.contains("/nix/store"), "{json}");
    // The output is deterministic.
    assert_eq!(json, to_json(&instantiate(&smoke_inputs()).unwrap()));
}

#[test]
fn layers_and_overrides() {
    let inputs = smoke_inputs();
    let out = instantiate(&inputs).unwrap();
    let unit = |id: &str| -> RenderedUnit {
        serde_json::from_str(&attr(&out.units[id], "BREAKBULK_UNIT")).unwrap()
    };
    let RenderedUnit::Compile(lib) = unit(LIB) else {
        panic!()
    };
    // Toolchain env, then the package override (which wins for SHARED).
    assert_eq!(lib.env["CFLAGS"], input_value("env:target:CFLAGS"));
    assert_eq!(
        lib.env["SHARED"],
        input_value("override:smokelib:env:target:SHARED")
    );
    assert_eq!(
        lib.env["LIB_ONLY"],
        input_value("override:smokelib:env:target:LIB_ONLY")
    );
    assert!(!lib.env.contains_key("HOST_ONLY"));
    assert_eq!(
        lib.env_capture.as_deref(),
        Some(input_value("override:smokelib:capture:target").as_str())
    );
    // The build script compiles on the host: no target env, no package
    // override (smokelib has none for host).
    let RenderedUnit::Compile(script) = unit(SCRIPT) else {
        panic!()
    };
    assert_eq!(script.env["HOST_ONLY"], input_value("env:host:HOST_ONLY"));
    assert!(!script.env.contains_key("CFLAGS") && !script.env.contains_key("LIB_ONLY"));
    assert_eq!(
        script.env_capture.as_deref(),
        Some(input_value("capture:host").as_str())
    );
    // `smokeapp@9.9.9` does not match smokeapp 0.1.0.
    let RenderedUnit::Compile(app) = unit(APP) else {
        panic!()
    };
    assert!(!app.env.contains_key("NEVER"));
    assert_eq!(
        app.env_capture.as_deref(),
        Some(input_value("capture:target").as_str())
    );
    let RenderedUnit::Run(run) = unit(RUN) else {
        panic!()
    };
    assert!(run.strict_sources);
    assert_eq!(run.env["RUSTC"], format!("{RUSTC}/bin/rustc"));
}

/// Layer 5 (the package override) appends to layer 4 (the toolchain spec)
/// for list-like variables, and both append to Cargo's recorded env (layer
/// 3), as `breakbulk_unit::env::merge_layer` does with real values. Empty
/// values leave no separator behind: an empty `PATH` entry would mean the
/// working directory.
#[test]
fn list_like_variables_append_across_layers() {
    let mut inputs = smoke_inputs();
    inputs.toolchains.target.env.extend([
        "PATH".into(),
        "NIX_CFLAGS_COMPILE".into(),
        "PKG_CONFIG_PATH".into(),
    ]);
    inputs
        .overrides
        .packages
        .get_mut("smokelib")
        .unwrap()
        .target
        .env
        .extend([
            "PATH".into(),
            "NIX_CFLAGS_COMPILE".into(),
            "PKG_CONFIG_PATH".into(),
        ]);
    // The recorded env of the library also has a PATH (layer 3).
    let lib = match inputs.plan.units.get_mut(LIB).unwrap() {
        Unit::Compile(c) => c,
        Unit::Run(_) => panic!(),
    };
    lib.env.insert(
        "PATH".into(),
        breakbulk_format::Text::Literal(format!("{RUSTC}/bin")),
    );
    let out = instantiate(&inputs).unwrap();
    let RenderedUnit::Compile(c) =
        serde_json::from_str(&attr(&out.units[LIB], "BREAKBULK_UNIT")).unwrap()
    else {
        panic!()
    };
    let spec = |v: &str| input_value(&keys::env(Platform::Target, v));
    let ov = |v: &str| input_value(&keys::override_env("smokelib", Platform::Target, v));
    assert_eq!(
        c.env["NIX_CFLAGS_COMPILE"],
        format!(
            "{} {}",
            spec("NIX_CFLAGS_COMPILE"),
            ov("NIX_CFLAGS_COMPILE")
        )
    );
    assert_eq!(
        c.env["PKG_CONFIG_PATH"],
        format!("{}:{}", spec("PKG_CONFIG_PATH"), ov("PKG_CONFIG_PATH"))
    );
    // The spec's PATH is empty: no empty entry between the recorded PATH
    // and the override's.
    assert_eq!(spec("PATH"), "");
    assert_eq!(c.env["PATH"], format!("{RUSTC}/bin:{}", ov("PATH")));
    // Not list-like: the override replaces the spec's value.
    assert_eq!(c.env["SHARED"], ov("SHARED"));
    // Identical to rendering with the real values.
    let direct =
        unit_env_value(&render_unit(&inputs.plan, &LIB.to_owned(), &RealPaths(&inputs)).unwrap())
            .unwrap();
    assert_eq!(attr(&out.units[LIB], "BREAKBULK_UNIT"), direct);
    // units.json still names no store path: the recorded PATH's store path
    // became a tool token inside the join.
    assert!(!to_json(&out).contains("/nix/store"));
    // A target unit without the override joins only the spec's values; the
    // empty spec PATH leaves no PATH at all in a unit that records none.
    let RenderedUnit::Compile(app) =
        serde_json::from_str(&attr(&out.units[APP], "BREAKBULK_UNIT")).unwrap()
    else {
        panic!()
    };
    assert_eq!(app.env["PATH"], "");
    assert_eq!(app.env["NIX_CFLAGS_COMPILE"], spec("NIX_CFLAGS_COMPILE"));
}

#[test]
fn versioned_override_wins() {
    let mut inputs = smoke_inputs();
    inputs.overrides.packages.insert(
        "smokelib@0.1.0".into(),
        PackageOverride {
            strict_sources: Some(false),
            ..Default::default()
        },
    );
    let out = instantiate(&inputs).unwrap();
    let RenderedUnit::Run(run) =
        serde_json::from_str(&attr(&out.units[RUN], "BREAKBULK_UNIT")).unwrap()
    else {
        panic!()
    };
    assert!(!run.strict_sources);
    assert!(!run.env.contains_key("LIB_ONLY"));
}

#[test]
fn names_and_outputs() {
    let out = instantiate(&smoke_inputs()).unwrap();
    let name = |id: &str| attr(&out.units[id], "name");
    assert_eq!(name(APP), "smokeapp-0.1.0-bin");
    assert_eq!(name(LIB), "smokelib-0.1.0-lib");
    assert_eq!(name(SCRIPT), "smokelib-0.1.0-build-script");
    assert_eq!(name(RUN), "smokelib-0.1.0-build-run");
    let outputs = |id: &str| out.units[id].attrs["outputs"].clone();
    assert_eq!(outputs(APP), Value::Strings(vec!["out".into()]));
    assert_eq!(
        outputs(LIB),
        Value::Strings(vec!["rlib".into(), "rmeta".into()])
    );
    assert_eq!(
        outputs(RUN),
        Value::Strings(vec!["flags".into(), "out".into()])
    );
}

#[test]
fn unit_name_for_other_crates() {
    let mut plan = smoke_plan();
    let Unit::Compile(c) = plan.units.get_mut(APP).unwrap() else {
        panic!()
    };
    c.krate.name = "admin_cli".into();
    assert_eq!(
        unit_name(APP, &plan.units[APP]),
        "smokeapp-0.1.0-bin-admin_cli"
    );
    let Unit::Compile(c) = plan.units.get_mut(APP).unwrap() else {
        panic!()
    };
    c.args.push(breakbulk_format::Arg::Literal("--test".into()));
    assert_eq!(
        unit_name(APP, &plan.units[APP]),
        "smokeapp-0.1.0-test-admin_cli"
    );
}

#[test]
fn undeclared_store_path_is_an_error() {
    let mut inputs = smoke_inputs();
    inputs.toolchains.tools.remove("rustc");
    let e = instantiate(&inputs).unwrap_err().0;
    assert!(
        e.contains("the store path /nix/store/00000000000000000000000000000000-rustc-1.99.0 is not a declared toolchain input"),
        "{e}"
    );
}

#[test]
fn tool_inside_a_store_path_and_longest_match() {
    let mut inputs = smoke_inputs();
    // A tool given as an executable path, and a shorter one that also
    // matches: the longest wins, and the rest of the path stays literal.
    inputs
        .toolchains
        .tools
        .insert("rustc-bin".into(), format!("{RUSTC}/bin/rustc"));
    let out = instantiate(&inputs).unwrap();
    let Value::Parts { parts } = &out.units[APP].attrs["BREAKBULK_UNIT"] else {
        panic!()
    };
    assert!(parts.contains(&Part::Input {
        input: "tool:rustc-bin".into(),
        json: false
    }));
    assert!(!parts.contains(&Part::Input {
        input: "tool:rustc".into(),
        json: false
    }));
    // Not a prefix at a path boundary: no match.
    let mut inputs = smoke_inputs();
    inputs
        .toolchains
        .tools
        .insert("rustc".into(), format!("{RUSTC}-x"));
    assert!(instantiate(&inputs).is_err());
}

#[test]
fn missing_source_view_is_an_error() {
    let mut inputs = smoke_inputs();
    inputs.sources.workspace.remove("smokeapp");
    let e = instantiate(&inputs).unwrap_err().0;
    assert!(
        e.contains("no source view for the package path+file:///build/skeleton/smokeapp#0.1.0 (directory `smokeapp`)"),
        "{e}"
    );
}

#[test]
fn token_prefix_avoids_plan_text() {
    let mut inputs = smoke_inputs();
    assert_eq!(token_prefix(&inputs), "@bb0:");
    let Unit::Compile(c) = inputs.plan.units.get_mut(APP).unwrap() else {
        panic!()
    };
    c.args
        .push(breakbulk_format::Arg::Literal("@bb0:0@".into()));
    assert_eq!(token_prefix(&inputs), "@bb1:");
    let out = instantiate(&inputs).unwrap();
    assert!(attr(&out.units[APP], "BREAKBULK_UNIT").contains("\"@bb0:0@\""));
}

#[test]
fn workspace_dirs() {
    let plan = smoke_plan();
    assert_eq!(
        workspace_dir(&plan, "path+file:///build/skeleton/a/b#x@0.1.0"),
        Some("a/b")
    );
    assert_eq!(
        workspace_dir(&plan, "path+file:///build/skeleton#0.1.0"),
        Some("")
    );
    assert_eq!(
        workspace_dir(&plan, "path+file:///build/skeletonx#0.1.0"),
        None
    );
    assert_eq!(workspace_dir(&plan, "registry+https://x#a@1.0.0"), None);
}

fn predicted(roots: Vec<PredictedRoot>) -> Option<PredictedRoots> {
    Some(PredictedRoots {
        variant: "dev".into(),
        roots,
    })
}

fn proot(target: &str, kind: RootKind, test: bool, rf: Option<&[&str]>) -> PredictedRoot {
    PredictedRoot {
        package: "smokeapp".into(),
        target: target.into(),
        kind,
        test,
        required_features: rf.map(|f| f.iter().map(|s| s.to_string()).collect()),
    }
}

#[test]
fn roots_without_prediction() {
    let out = instantiate(&smoke_inputs()).unwrap();
    assert_eq!(
        out.roots.keys().collect::<Vec<_>>(),
        ["smokeapp/bin/smokeapp"]
    );
    assert_eq!(
        out.roots["smokeapp/bin/smokeapp"].what,
        RootWhat::Unit {
            unit: APP.into(),
            output: "out".into()
        }
    );
}

#[test]
fn predicted_roots_and_stubs() {
    let mut inputs = smoke_inputs();
    inputs.roots = predicted(vec![
        proot("smokeapp", RootKind::Bin, false, None),
        proot("admin-cli", RootKind::Bin, false, Some(&["cli"])),
        proot("it", RootKind::Test, true, Some(&[])),
    ]);
    let out = instantiate(&inputs).unwrap();
    assert_eq!(
        out.roots.keys().collect::<Vec<_>>(),
        [
            "smokeapp/bin/admin-cli",
            "smokeapp/bin/smokeapp",
            "smokeapp/test/it"
        ]
    );
    let RootWhat::Stub { reason, stub } = &out.roots["smokeapp/bin/admin-cli"].what else {
        panic!()
    };
    assert_eq!(
        reason,
        "`admin-cli` was not built by Cargo in variant `dev`: required features `[cli]` not enabled"
    );
    assert_eq!(attr(stub, "message"), *reason);
    assert_eq!(attr(stub, "builder"), SHELL);
    assert_eq!(attr(stub, "name"), "smokeapp-bin-admin-cli-not-built");
    let Value::Strings(args) = &stub.attrs["args"] else {
        panic!()
    };
    assert!(args[1].contains("exit 1"));
    let RootWhat::Stub { reason, stub } = &out.roots["smokeapp/test/it"].what else {
        panic!()
    };
    assert_eq!(
        reason,
        "`it` was skipped: not built by Cargo in variant `dev`: Cargo did not select it"
    );
    let Value::Strings(args) = &stub.attrs["args"] else {
        panic!()
    };
    assert!(!args[1].contains("exit 1") && args[1].contains("$out"));
}

#[test]
fn unpredicted_root_is_an_error() {
    let mut inputs = smoke_inputs();
    inputs.roots = predicted(vec![proot("other", RootKind::Bin, false, None)]);
    let e = instantiate(&inputs).unwrap_err().0;
    assert!(e.contains("not predicted: smokeapp/bin/smokeapp."), "{e}");
    assert!(e.contains("plan roots:      smokeapp/bin/smokeapp"), "{e}");
    assert!(e.contains("predicted roots: smokeapp/bin/other"), "{e}");
    // A test root is a different root from the plain bin.
    inputs.roots = predicted(vec![proot("smokeapp", RootKind::Bin, true, None)]);
    let e = instantiate(&inputs).unwrap_err().0;
    assert!(
        e.contains("predicted roots: smokeapp/bin-test/smokeapp"),
        "{e}"
    );
}

#[test]
fn missing_tools_are_errors() {
    let mut inputs = smoke_inputs();
    inputs.toolchains.tools.remove(TOOL_SHELL);
    assert_eq!(
        instantiate(&inputs).unwrap_err().0,
        "toolchains.json: the tool `shell` is missing"
    );
}

/// The Nix side escapes `json` inputs with `builtins.toJSON`; it must match
/// `serde_json` byte for byte. The expected bytes are Nix's output (Determinate
/// Nix 3.22.2, Nix 2.35.2) for the same string: `"`, `\`, `\b`, `\f`, `\n`,
/// `\r`, `\t` short forms, other C0 controls as lowercase `\u00xx`, and DEL,
/// U+2028, non-ASCII and `/` verbatim.
#[test]
fn escaping_matches_nix_to_json() {
    let s = "a\"b\\c\n\t\r\u{1}\u{8}\u{c}\u{1f}\u{7f}\u{2028}é€😀/";
    let nix = "\"a\\\"b\\\\c\\n\\t\\r\\u0001\\b\\f\\u001f\u{7f}\u{2028}é€😀/\"";
    assert_eq!(serde_json::to_string(s).unwrap(), nix);
}
