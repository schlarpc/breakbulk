//! Dynamic-derivation mode's resolution (`crate::dynamic`) against what
//! `lib/instantiate.nix` does with the same `units.json`.

use std::collections::{BTreeMap, BTreeSet};

use super::*;
use crate::dynamic::{
    COREUTILS_KEY, Context, InputValue, Outer, Values, Written, dynamic_plan, resolve,
};

const COREUTILS: &str = "/nix/store/77777777777777777777777777777777-coreutils";

fn drv_of(key: &str) -> String {
    format!(
        "/nix/store/88888888888888888888888888888888-{}.drv",
        key.replace(':', "_")
    )
}

/// The context Nix would give each value in these tests: tools and
/// captures are derivation outputs, sources are plain paths.
fn context_of(key: &str) -> Vec<Context> {
    if key.starts_with("src:") {
        vec![Context::Opaque {
            path: input_value(key),
        }]
    } else if key.starts_with("tool:") || key.contains("capture:") {
        vec![Context::Built {
            drv: drv_of(key),
            outputs: vec!["out".into()],
        }]
    } else {
        vec![]
    }
}

fn values(inputs: &Inputs) -> Values {
    let mut keys: Vec<String> = vec![COREUTILS_KEY.into()];
    keys.extend(inputs.sources.workspace.iter().map(|d| keys::src(d)));
    keys.extend(inputs.toolchains.tools.keys().map(|t| keys::tool(t)));
    for p in [Platform::Host, Platform::Target] {
        keys.push(keys::capture(p));
        keys.extend(
            inputs
                .toolchains
                .platform(p)
                .env
                .iter()
                .map(|v| keys::env(p, v)),
        );
        for (k, o) in &inputs.overrides.packages {
            keys.push(keys::override_capture(k, p));
            keys.extend(
                o.platform(p)
                    .env
                    .iter()
                    .map(|v| keys::override_env(k, p, v)),
            );
        }
    }
    keys.into_iter()
        .map(|k| {
            let v = if k == COREUTILS_KEY {
                InputValue {
                    value: COREUTILS.into(),
                    context: vec![Context::Built {
                        drv: drv_of("coreutils"),
                        outputs: vec!["out".into()],
                    }],
                }
            } else {
                InputValue {
                    value: input_value(&k),
                    context: context_of(&k),
                }
            };
            (k, v)
        })
        .collect()
}

fn outer(names: &[&str]) -> Outer {
    Outer {
        name: "ws-x86_64-unknown-linux-gnu-dev".into(),
        outputs: names
            .iter()
            .map(|n| (n.to_string(), format!("{}.drv", n.replace('/', "."))))
            .collect(),
        units: Some("units.drv".into()),
    }
}

fn dyn_inputs() -> Inputs {
    let mut inputs = smoke_inputs();
    inputs.roots = predicted(vec![
        proot("smokeapp", RootKind::Bin, false, None),
        proot("admin-cli", RootKind::Bin, false, Some(&["cli"])),
        proot("it", RootKind::Test, true, Some(&[])),
    ]);
    inputs
}

const ROOTS: [&str; 3] = [
    "smokeapp/bin/admin-cli",
    "smokeapp/bin/smokeapp",
    "smokeapp/test/it",
];

/// Write every node with the paths `unit_path` gives, as the outer builder
/// would with the real ones.
fn write_all(
    inputs: &Inputs,
) -> (
    Vec<(String, crate::dynamic::Resolved)>,
    BTreeMap<String, Written>,
) {
    let units = instantiate(inputs).unwrap();
    let plan = dynamic_plan(inputs, &units, &outer(&ROOTS)).unwrap();
    let vals = values(inputs);
    let mut written = BTreeMap::new();
    let mut out = Vec::new();
    for n in &plan.nodes {
        let r = resolve(&n.drv, &vals, &written, units.pass_as_file_above).unwrap();
        let outputs = r
            .outputs
            .iter()
            .map(|o| (o.clone(), unit_path(&n.key, o)))
            .collect();
        written.insert(
            n.key.clone(),
            Written {
                drv_path: drv_of(&n.key),
                outputs,
            },
        );
        out.push((n.key.clone(), r));
    }
    (out, written)
}

#[test]
fn resolved_units_equal_nix_substitution() {
    let inputs = dyn_inputs();
    let units = instantiate(&inputs).unwrap();
    let (resolved, _) = write_all(&inputs);
    let by_key: BTreeMap<&str, &crate::dynamic::Resolved> =
        resolved.iter().map(|(k, r)| (k.as_str(), r)).collect();
    for (id, d) in &units.units {
        let r = by_key[id.as_str()];
        // What lib/instantiate.nix substitutes (the tests' `resolve`).
        assert_eq!(
            r.env["BREAKBULK_UNIT"],
            attr(d, "BREAKBULK_UNIT"),
            "unit {id}"
        );
        assert_eq!(r.builder, UNIT);
        assert_eq!(r.env["builder"], UNIT);
        assert_eq!(r.args, ["unit"]);
        assert_eq!(r.system, "x86_64-linux");
        assert_eq!(r.env["name"], r.name);
        assert!(!r.env.contains_key("args"));
        let Value::Strings(outs) = &d.attrs["outputs"] else {
            panic!()
        };
        assert_eq!(&r.outputs, outs);
        assert_eq!(r.env["outputs"], outs.join(" "));
        assert!(!r.env.contains_key("passAsFile"));
        // The builder's context: the breakbulk-unit derivation.
        assert!(r.input_drvs[&drv_of("tool:breakbulk-unit")].contains("out"));
    }
    // The app links the lib: its rlib is an input, by the lib's .drv.
    let app = by_key[APP];
    assert!(
        app.input_drvs[&drv_of(LIB)].contains("rlib"),
        "{:?}",
        app.input_drvs
    );
    assert!(
        app.input_srcs.contains(&input_value("src:smokeapp")),
        "{:?}",
        app.input_srcs
    );
    // The lib's build-script run, through its flags.
    let lib = by_key[LIB];
    assert_eq!(
        lib.input_drvs[&drv_of(RUN)],
        BTreeSet::from(["flags".to_owned(), "out".to_owned()])
    );
}

#[test]
fn nodes_are_in_dependency_order() {
    let inputs = dyn_inputs();
    let units = instantiate(&inputs).unwrap();
    let plan = dynamic_plan(&inputs, &units, &outer(&ROOTS)).unwrap();
    let pos: BTreeMap<&str, usize> = plan
        .nodes
        .iter()
        .enumerate()
        .map(|(i, n)| (n.key.as_str(), i))
        .collect();
    assert!(pos[SCRIPT] < pos[RUN] && pos[RUN] < pos[LIB] && pos[LIB] < pos[APP]);
    // Units, then each root's stub, then the wrappers, which are the only
    // nodes submitted.
    let submitted: Vec<(&str, &str)> = plan
        .nodes
        .iter()
        .filter_map(|n| Some((n.key.as_str(), n.submit_as.as_deref()?)))
        .collect();
    assert_eq!(
        submitted,
        [
            (
                "wrapper:smokeapp/bin/admin-cli",
                "smokeapp.bin.admin-cli.drv"
            ),
            ("wrapper:smokeapp/bin/smokeapp", "smokeapp.bin.smokeapp.drv"),
            ("wrapper:smokeapp/test/it", "smokeapp.test.it.drv"),
            ("wrapper:*units", "units.drv"),
        ]
    );
    assert!(pos.contains_key("stub:smokeapp/test/it"));
    assert_eq!(plan.nodes.last().unwrap().key, "wrapper:*units");
}

#[test]
fn units_output_depends_on_every_unit_output() {
    let inputs = dyn_inputs();
    let (resolved, _) = write_all(&inputs);
    let (_, u) = resolved
        .iter()
        .find(|(k, _)| k == "wrapper:*units")
        .unwrap();
    assert_eq!(u.name, "ws-x86_64-unknown-linux-gnu-dev-units");
    for (id, unit) in &inputs.plan.units {
        for o in unit_outputs(unit) {
            assert!(u.input_drvs[&drv_of(id)].contains(&o), "{id} {o}");
            assert!(u.env["units"].contains(&unit_path(id, &o)));
        }
    }
    // No stub: a check variant has no roots.
    assert!(!u.input_drvs.keys().any(|d| d.contains("stub")));
}

#[test]
fn wrappers() {
    let inputs = dyn_inputs();
    let (resolved, _) = write_all(&inputs);
    let by_key: BTreeMap<&str, &crate::dynamic::Resolved> =
        resolved.iter().map(|(k, r)| (k.as_str(), r)).collect();
    let w = by_key["wrapper:smokeapp/bin/smokeapp"];
    // Nix requires `<outer name>-<output name without .drv>`.
    assert_eq!(
        w.name,
        "ws-x86_64-unknown-linux-gnu-dev-smokeapp.bin.smokeapp"
    );
    assert_eq!(w.builder, SHELL);
    assert_eq!(w.outputs, ["out"]);
    assert_eq!(w.env["root"], unit_path(APP, "out"));
    assert_eq!(w.env["PATH"], format!("{COREUTILS}/bin"));
    assert!(w.input_drvs[&drv_of(APP)].contains("out"));
    assert!(w.input_drvs[&drv_of("coreutils")].contains("out"));
    let info: serde_json::Value = serde_json::from_str(&w.env["rootJson"]).unwrap();
    assert_eq!(info["unit"], APP);
    assert_eq!(info["reason"], serde_json::Value::Null);
    assert!(info.get("testSpec").is_none());

    // A product root Cargo did not build: the wrapper is the stub's.
    let w = by_key["wrapper:smokeapp/bin/admin-cli"];
    assert_eq!(
        w.env["root"],
        unit_path("stub:smokeapp/bin/admin-cli", "out")
    );
    let info: serde_json::Value = serde_json::from_str(&w.env["rootJson"]).unwrap();
    assert!(
        info["reason"]
            .as_str()
            .unwrap()
            .contains("required features `[cli]`")
    );
    assert_eq!(info["unit"], serde_json::Value::Null);
}

#[test]
fn test_spec_of_a_test_root() {
    let mut inputs = dyn_inputs();
    inputs.roots = predicted(vec![proot("smokeapp", RootKind::Bin, false, None)]);
    // Make the plan's app a test binary with runtime env.
    let mut plan = inputs.plan.clone();
    let Some(breakbulk_format::Unit::Compile(c)) = plan.units.get_mut(APP) else {
        panic!()
    };
    c.env.insert(
        "CARGO_PKG_NAME".into(),
        breakbulk_format::Text::Literal("smokeapp".into()),
    );
    c.env.insert(
        "OUT_DIR".into(),
        breakbulk_format::Text::Literal("/compile/time/only".into()),
    );
    // `[env]` variables Cargo set (the plan's configEnv), one of them a
    // `relative` path into the package source; and one the plan does not
    // name (not from `[env]`).
    let src = c.cwd.clone();
    c.env.insert(
        "BB_PLAIN".into(),
        breakbulk_format::Text::Literal("plain".into()),
    );
    c.env.insert(
        "BB_REL".into(),
        breakbulk_format::Text::Concat(vec![
            breakbulk_format::Piece::Ref(src),
            breakbulk_format::Piece::Literal("/data".into()),
        ]),
    );
    c.env.insert(
        "NOT_CONFIG".into(),
        breakbulk_format::Text::Literal("x".into()),
    );
    plan.config_env = ["BB_PLAIN", "BB_REL", "CARGO_PKG_NAME"]
        .into_iter()
        .map(String::from)
        .collect();
    for r in &mut plan.roots {
        r.test = true;
    }
    inputs.plan = plan;
    inputs.roots = predicted(vec![proot("smokeapp", RootKind::Bin, true, None)]);
    let units = instantiate(&inputs).unwrap();
    let plan = dynamic_plan(&inputs, &units, &outer(&["smokeapp/bin-test/smokeapp"])).unwrap();
    let vals = values(&inputs);
    let mut written = BTreeMap::new();
    let mut wrapper = None;
    for n in &plan.nodes {
        let r = resolve(&n.drv, &vals, &written, units.pass_as_file_above).unwrap();
        written.insert(
            n.key.clone(),
            Written {
                drv_path: drv_of(&n.key),
                outputs: r
                    .outputs
                    .iter()
                    .map(|o| (o.clone(), unit_path(&n.key, o)))
                    .collect(),
            },
        );
        if n.key == "wrapper:smokeapp/bin-test/smokeapp" {
            wrapper = Some(r);
        }
    }
    let w = wrapper.unwrap();
    let info: serde_json::Value = serde_json::from_str(&w.env["rootJson"]).unwrap();
    let spec = &info["testSpec"];
    assert_eq!(spec["env"]["CARGO_PKG_NAME"], "smokeapp");
    assert!(spec["env"].get("OUT_DIR").is_none());
    // The `[env]` variables, as IFD mode's runSpec gives them: runtime
    // variables stay in `env`, references are real paths.
    let config_env = spec["configEnv"].as_object().unwrap();
    assert_eq!(
        config_env.keys().collect::<Vec<_>>(),
        ["BB_PLAIN", "BB_REL"]
    );
    assert_eq!(config_env["BB_PLAIN"], "plain");
    let rel = config_env["BB_REL"].as_str().unwrap();
    assert!(
        rel.starts_with("/nix/store/") && rel.ends_with("/data"),
        "{rel}"
    );
    // Every target-platform run, for the dynamic-library path; the paths
    // are the wrapper's inputs.
    let runs: Vec<&str> = inputs
        .plan
        .units
        .iter()
        .filter(
            |(_, u)| matches!(u, breakbulk_format::Unit::Run(r) if r.platform == Platform::Target),
        )
        .map(|(id, _)| id.as_str())
        .collect();
    assert_eq!(
        spec["dylibFlags"],
        serde_json::json!(
            runs.iter()
                .map(|r| unit_path(r, "flags"))
                .collect::<Vec<_>>()
        )
    );
    for r in runs {
        assert!(w.input_drvs[&drv_of(r)].contains("flags"));
    }
}

#[test]
fn every_root_needs_an_output() {
    let inputs = dyn_inputs();
    let units = instantiate(&inputs).unwrap();
    let e = dynamic_plan(&inputs, &units, &outer(&ROOTS[..2]))
        .unwrap_err()
        .0;
    assert!(e.contains("smokeapp/test/it"), "{e}");
    let mut o = outer(&ROOTS);
    o.outputs.insert(
        "smokeapp/test/it".into(),
        "smokeapp.bin.smokeapp.drv".into(),
    );
    let e = dynamic_plan(&inputs, &units, &o).unwrap_err().0;
    assert!(e.contains("same output name"), "{e}");
}

#[test]
fn missing_value_is_an_error() {
    let inputs = dyn_inputs();
    let units = instantiate(&inputs).unwrap();
    let plan = dynamic_plan(&inputs, &units, &outer(&ROOTS)).unwrap();
    let mut vals = values(&inputs);
    vals.remove(&keys::tool(TOOL_UNIT));
    let first = &plan.nodes[0];
    let e = resolve(
        &first.drv,
        &vals,
        &BTreeMap::new(),
        units.pass_as_file_above,
    )
    .unwrap_err()
    .0;
    assert!(e.contains("tool:breakbulk-unit"), "{e}");
}

#[test]
fn long_units_pass_as_file() {
    let inputs = dyn_inputs();
    let units = instantiate(&inputs).unwrap();
    let plan = dynamic_plan(&inputs, &units, &outer(&ROOTS)).unwrap();
    let vals = values(&inputs);
    let n = &plan.nodes[0];
    let r = resolve(&n.drv, &vals, &BTreeMap::new(), 10).unwrap();
    assert_eq!(r.env["passAsFile"], "BREAKBULK_UNIT");
}

/// A list-like variable joined from several env layers resolves as the Nix
/// side resolves it: empty layers left out.
#[test]
fn joined_env_layers_resolve_as_nix_does() {
    let mut inputs = dyn_inputs();
    inputs
        .toolchains
        .target
        .env
        .extend(["PATH".into(), "PKG_CONFIG_PATH".into()]);
    inputs
        .overrides
        .packages
        .get_mut("smokelib")
        .unwrap()
        .target
        .env
        .extend(["PATH".into(), "PKG_CONFIG_PATH".into()]);
    let units = instantiate(&inputs).unwrap();
    let (resolved, _) = write_all(&inputs);
    let lib = &resolved.iter().find(|(k, _)| k == LIB).unwrap().1;
    assert_eq!(
        lib.env["BREAKBULK_UNIT"],
        attr(&units.units[LIB], "BREAKBULK_UNIT")
    );
    let RenderedUnit::Compile(c) = serde_json::from_str(&lib.env["BREAKBULK_UNIT"]).unwrap() else {
        panic!()
    };
    let ov = |v: &str| input_value(&keys::override_env("smokelib", Platform::Target, v));
    // The spec's PATH is empty in these tests (`input_value`).
    assert_eq!(c.env["PATH"], ov("PATH"));
    assert_eq!(
        c.env["PKG_CONFIG_PATH"],
        format!(
            "{}:{}",
            input_value(&keys::env(Platform::Target, "PKG_CONFIG_PATH")),
            ov("PKG_CONFIG_PATH")
        )
    );
}
