//! The per-unit specification `breakbulk-unit` reads from `BREAKBULK_UNIT`.
//!
//! This is a unit from `plan.json` after instantiation: every reference
//! (`src`, `crateSrc`, `out`) is rendered to a literal path, and every splice
//! names the `flags` output directory of its build-script run instead of the
//! run's unit id. `breakbulk-format` produces it; it lives here so that
//! `breakbulk-unit`, an input of every unit, does not depend on the plan format.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// What a splice point expands to: one kind of directive from one run.
///
/// The names are the directive keys of the `cargo::` syntax. The two spellings
/// of the cdylib directive (`rustc-link-arg-cdylib`, `rustc-cdylib-link-arg`)
/// are one kind, as in Cargo.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SpliceKind {
    RustcCfg,
    RustcCheckCfg,
    RustcEnv,
    RustcLinkLib,
    RustcLinkSearch,
    RustcLinkArg,
    RustcLinkArgBins,
    /// `rustc-link-arg-bin=NAME=ARG`; the splice carries `bin`.
    RustcLinkArgBin,
    RustcLinkArgTests,
    RustcLinkArgBenches,
    RustcLinkArgExamples,
    RustcLinkArgCdylib,
}

impl SpliceKind {
    pub const ALL: [SpliceKind; 12] = [
        SpliceKind::RustcCfg,
        SpliceKind::RustcCheckCfg,
        SpliceKind::RustcEnv,
        SpliceKind::RustcLinkLib,
        SpliceKind::RustcLinkSearch,
        SpliceKind::RustcLinkArg,
        SpliceKind::RustcLinkArgBins,
        SpliceKind::RustcLinkArgBin,
        SpliceKind::RustcLinkArgTests,
        SpliceKind::RustcLinkArgBenches,
        SpliceKind::RustcLinkArgExamples,
        SpliceKind::RustcLinkArgCdylib,
    ];

    /// The directive key, as written after `cargo::`.
    pub fn as_str(self) -> &'static str {
        match self {
            SpliceKind::RustcCfg => "rustc-cfg",
            SpliceKind::RustcCheckCfg => "rustc-check-cfg",
            SpliceKind::RustcEnv => "rustc-env",
            SpliceKind::RustcLinkLib => "rustc-link-lib",
            SpliceKind::RustcLinkSearch => "rustc-link-search",
            SpliceKind::RustcLinkArg => "rustc-link-arg",
            SpliceKind::RustcLinkArgBins => "rustc-link-arg-bins",
            SpliceKind::RustcLinkArgBin => "rustc-link-arg-bin",
            SpliceKind::RustcLinkArgTests => "rustc-link-arg-tests",
            SpliceKind::RustcLinkArgBenches => "rustc-link-arg-benches",
            SpliceKind::RustcLinkArgExamples => "rustc-link-arg-examples",
            SpliceKind::RustcLinkArgCdylib => "rustc-link-arg-cdylib",
        }
    }

    /// True for `rustc-link-arg` and its target-specific forms.
    pub fn is_link_arg(self) -> bool {
        matches!(
            self,
            SpliceKind::RustcLinkArg
                | SpliceKind::RustcLinkArgBins
                | SpliceKind::RustcLinkArgBin
                | SpliceKind::RustcLinkArgTests
                | SpliceKind::RustcLinkArgBenches
                | SpliceKind::RustcLinkArgExamples
                | SpliceKind::RustcLinkArgCdylib
        )
    }
}

impl std::fmt::Display for SpliceKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A splice point: "run `splice`'s directives of `kind` go here".
///
/// `S` names the run: a unit id in `plan.json`, the run's `flags` directory in
/// `BREAKBULK_UNIT`.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Splice<S = String> {
    pub splice: S,
    pub kind: SpliceKind,
    /// The bin target name, for `rustc-link-arg-bin` only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bin: Option<String>,
}

/// A target of the package a build script belongs to, as `cargo metadata`
/// reports it. Used for Cargo's `rustc-link-arg-*` validations.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PackageTarget {
    pub name: String,
    /// `cargo metadata`'s `kind`: `bin`, `example`, `test`, `bench`,
    /// `custom-build`, or the crate types of a library (`lib`, `rlib`,
    /// `cdylib`, …).
    pub kind: Vec<String>,
}

impl PackageTarget {
    fn has_kind(&self, k: &str) -> bool {
        self.kind.iter().any(|x| x == k)
    }
    /// Cargo's `Target::is_bin`.
    pub fn is_bin(&self) -> bool {
        self.has_kind("bin")
    }
    /// Cargo's `Target::is_test`.
    pub fn is_test(&self) -> bool {
        self.has_kind("test")
    }
    /// Cargo's `Target::is_bench`.
    pub fn is_bench(&self) -> bool {
        self.has_kind("bench")
    }
    /// Cargo's `Target::is_example` (any example, whatever its crate type).
    pub fn is_example(&self) -> bool {
        self.has_kind("example")
    }
    /// Cargo's `Target::is_cdylib`: a library target with crate type `cdylib`.
    /// `cargo metadata` lists a library's crate types as its kinds, and an
    /// example's kind as `example` whatever its crate type.
    pub fn is_cdylib(&self) -> bool {
        self.has_kind("cdylib")
    }
}

/// `host` or `target`, observed from Cargo's output layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Platform {
    Host,
    Target,
}

/// One argument of a rendered compile: a literal, or a splice point.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RenderedArg {
    Literal(String),
    Splice(Splice<String>),
}

/// The crate a compile unit builds.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CrateInfo {
    pub name: String,
    pub types: Vec<String>,
    pub edition: String,
}

/// `BREAKBULK_UNIT`: one unit with every reference rendered.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum RenderedUnit {
    Compile(RenderedCompile),
    Run(RenderedRun),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RenderedCompile {
    pub package: String,
    #[serde(rename = "crate")]
    pub krate: CrateInfo,
    pub platform: Platform,
    pub program: Vec<String>,
    pub args: Vec<RenderedArg>,
    pub env: BTreeMap<String, String>,
    pub env_splices: Vec<Splice<String>>,
    pub cwd: String,
    /// Output name (`rmeta`, `rlib`, `bin`) to the file names rustc writes
    /// for it. `bin` files go to the derivation output `out`; every other
    /// name is its own derivation output.
    pub outputs: BTreeMap<String, Vec<String>>,
    /// The crate files of every transitive dependency (`.rmeta`, `.rlib` or
    /// a proc macro's shared library). `breakbulk-unit` symlinks them into
    /// one directory and passes it as the only `-L dependency=`.
    pub deps: Vec<String>,
    /// `--remap-path-prefix` pairs (from, to) that `breakbulk-unit` adds.
    /// Empty when Cargo's own `trim-paths` remaps are in the arguments.
    pub remap: Vec<(String, String)>,
    /// The `--remap-path-scope` value to add with `remap`; `None` adds no
    /// scope flag, which means every scope.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remap_scope: Option<String>,
    /// Layer 2 of the environment contract: an `env.json` file (a JSON object
    /// of strings) captured from nixpkgs' setup hooks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env_capture: Option<String>,
}

/// The name and version in a Cargo package id spec, as `cargo metadata`
/// writes them: `registry+https://…#ring@0.17.14`, or `path+file:///…/app#0.1.0`
/// where the name is the URL's last path segment. Returns `None` for other
/// shapes.
pub fn package_name_version(id: &str) -> Option<(&str, &str)> {
    let (url, frag) = id.rsplit_once('#')?;
    if let Some((name, version)) = frag.split_once('@') {
        return Some((name, version));
    }
    let path = url.split(['?', '#']).next()?;
    let name = path.trim_end_matches('/').rsplit('/').next()?;
    (!name.is_empty() && !frag.is_empty()).then_some((name, frag))
}

/// Cargo's description of a package in messages (`PackageId`'s `Display`):
/// `name vX.Y.Z`, followed by the source for packages not from crates.io.
pub fn package_descr(id: &str) -> String {
    match package_name_version(id) {
        Some((name, version)) => {
            let source = id.rsplit_once('#').map_or(id, |(u, _)| u);
            if source == "registry+https://github.com/rust-lang/crates.io-index" {
                format!("{name} v{version}")
            } else {
                let source = source.strip_prefix("path+file://").unwrap_or(source);
                format!("{name} v{version} ({source})")
            }
        }
        None => id.to_owned(),
    }
}

/// The derivation output a compile output name goes to: `bin` → `out`.
pub fn derivation_output(output: &str) -> &str {
    match output {
        "bin" => "out",
        o => o,
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RenderedRun {
    pub package: String,
    pub platform: Platform,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub links: Option<String>,
    /// The build-script executable.
    pub script: String,
    pub env: BTreeMap<String, String>,
    pub cwd: String,
    /// The `flags` directories of the upstream runs whose `metadata.json`
    /// becomes `DEP_<LINKS>_<KEY>` in this run's env.
    pub metadata_from: Vec<String>,
    /// The package's `rust-version`, for Cargo's `cargo::` syntax check.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rust_version: Option<String>,
    /// The package's targets, for Cargo's `rustc-link-arg-*` validations.
    pub targets: Vec<PackageTarget>,
    /// Cargo's `nightly_features_allowed` for the planning toolchain: decides
    /// whether `rustc-env=RUSTC_BOOTSTRAP=…` is an error or a warning.
    pub nightly_features_allowed: bool,
    /// Layer 2 of the environment contract, as for compile units.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env_capture: Option<String>,
    /// Fail a successful run whose `rerun-if-changed` paths are missing
    /// from the sandbox, instead of only warning.
    pub strict_sources: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splice_kind_names_round_trip() {
        for k in SpliceKind::ALL {
            let json = serde_json::to_string(&k).unwrap();
            assert_eq!(json, format!("\"{}\"", k.as_str()));
            assert_eq!(serde_json::from_str::<SpliceKind>(&json).unwrap(), k);
        }
    }

    #[test]
    fn package_ids() {
        let ring = "registry+https://github.com/rust-lang/crates.io-index#ring@0.17.14";
        assert_eq!(package_name_version(ring), Some(("ring", "0.17.14")));
        assert_eq!(package_descr(ring), "ring v0.17.14");
        let app = "path+file:///build/skeleton/app#0.1.0";
        assert_eq!(package_name_version(app), Some(("app", "0.1.0")));
        assert_eq!(package_descr(app), "app v0.1.0 (/build/skeleton/app)");
        assert_eq!(
            package_name_version("path+file:///w/crates/x#other@1.0.0"),
            Some(("other", "1.0.0"))
        );
        assert_eq!(
            package_name_version("git+https://example.com/r/foo?rev=abc#0.2.0"),
            Some(("foo", "0.2.0"))
        );
        assert_eq!(package_name_version("cfg-if"), None);
        assert_eq!(package_descr("cfg-if"), "cfg-if");
    }

    #[test]
    fn rendered_args_parse() {
        let args: Vec<RenderedArg> = serde_json::from_str(
            r#"["--cfg", {"splice": "/nix/store/x-flags", "kind": "rustc-cfg"},
                {"splice": "/f", "kind": "rustc-link-arg-bin", "bin": "app"}]"#,
        )
        .unwrap();
        assert_eq!(args[0], RenderedArg::Literal("--cfg".into()));
        assert_eq!(
            args[2],
            RenderedArg::Splice(Splice {
                splice: "/f".into(),
                kind: SpliceKind::RustcLinkArgBin,
                bin: Some("app".into())
            })
        );
        assert!(
            serde_json::from_str::<RenderedArg>(r#"{"splice": "/f", "kind": "nope"}"#).is_err()
        );
        assert!(
            serde_json::from_str::<RenderedArg>(r#"{"splice": "/f", "kind": "rustc-cfg", "x": 1}"#)
                .is_err()
        );
    }
}
