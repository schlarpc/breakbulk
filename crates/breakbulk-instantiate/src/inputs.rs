//! The evaluation-time inputs of instantiation, as `lib/instantiate.nix`
//! writes them.
//!
//! None of these files carries a value that ends up in a unit derivation
//! except tool store paths, which are needed to recognise literal store paths
//! in the plan. Everything else is named by key: the Nix side substitutes the
//! real value (with its string context) for each key. So the files change,
//! and instantiation reruns, only when the set of sources, tools, env
//! variables or roots changes, not when a source, a tool or an env value
//! does.

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_format::{Platform, RootKind};
use serde::Deserialize;

/// `sources.json`: which sources exist.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Sources {
    /// Workspace packages (and path packages), by their directory relative
    /// to the repository root (`""` for the root). Their source views are
    /// rooted at the repository root, like the planning skeleton.
    #[serde(default)]
    pub workspace: BTreeSet<String>,
    /// Workspace packages whose test units (test harnesses and doctests)
    /// get a wider source view (`test.sourceScope`), by directory.
    #[serde(default)]
    pub workspace_test: BTreeSet<String>,
    /// The Cargo targets (`<kind>/<name>`) whose units get a view of their
    /// own in place of their package's normal view, by directory. A unit
    /// whose target is not listed (or that the plan matched to none) gets
    /// the package's view.
    #[serde(default)]
    pub workspace_targets: BTreeMap<String, BTreeSet<String>>,
    /// The same for the test view.
    #[serde(default)]
    pub workspace_test_targets: BTreeMap<String, BTreeSet<String>>,
    /// The roots of a package's targets that the views of its other
    /// targets leave out (relative to the repository root), by directory.
    /// Only for hints, as `test_only`.
    #[serde(default)]
    pub target_roots: BTreeMap<String, Vec<String>>,
    /// The view keys (`src:<dir>#<kind>/<name>`, listed in
    /// `workspace_targets` or `workspace_test_targets`) whose views source
    /// prediction narrows. Only for hints: a unit with one names
    /// `predictSources.keep` for a path its view lacks.
    #[serde(default)]
    pub predicted: BTreeSet<String>,
    /// Workspace members with a tree of the workspace wrapper's config
    /// files (`variants.<v>.wrapperConfig.search`: clippy's `.clippy.toml`
    /// and `clippy.toml`) of the package directory and its ancestors up to
    /// the repository root, rooted there like source views, by directory.
    /// The variable that names it is the toolchains' `wrapperConfigVar`.
    #[serde(default)]
    pub wrapper_config: BTreeSet<String>,
    /// Path packages' test-only paths (relative to the repository root),
    /// which their normal source views leave out, by directory. Only for
    /// hints ([`breakbulk_format::Resolve::source_view`]).
    #[serde(default)]
    pub test_only: BTreeMap<String, Vec<String>>,
    /// What every view of a path package leaves out as junk (`target/`,
    /// `.git`, Nix's `result` symlinks), relative to the repository root,
    /// by directory. Only for hints, as `test_only`.
    #[serde(default)]
    pub junk: BTreeMap<String, Vec<String>>,
    /// Path packages whose `sources` functions choose their views' files,
    /// by directory. Only for hints, as `test_only`.
    #[serde(default)]
    pub custom: BTreeSet<String>,
    /// Fetched crate sources, by Cargo package id.
    #[serde(default)]
    pub crates: BTreeSet<String>,
}

/// `toolchains.json`.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Toolchains {
    /// The `system` of every unit derivation: the planner's system.
    pub system: String,
    /// The Nix store directory, for recognising literal store paths.
    #[serde(default = "default_store_dir")]
    pub store_dir: String,
    /// Tool name to its path, a store path or a path inside one (without
    /// string context). Must contain `breakbulk-unit` (the unit builder
    /// executable) and `shell` (a bash executable, for root stubs). A
    /// literal store path in the plan must start with one of these.
    pub tools: BTreeMap<String, String>,
    #[serde(default)]
    pub host: PlatformSpec,
    #[serde(default)]
    pub target: PlatformSpec,
    /// The `--remap-path-scope` of each kind of unit (the Nix library's
    /// `products.remapScope`). Every unit remaps every scope when rustc
    /// has no `--remap-path-scope` (`capabilities`; "Source paths at run
    /// time" in `docs/src/reference/unit-builder.md`).
    #[serde(default)]
    pub remap_scope: RemapScope,
    /// `sourcePaths = "keep"`: add no remaps of breakbulk's
    /// own, Rust or C ([`breakbulk_format::Resolve::keep_source_paths`]).
    #[serde(default)]
    pub keep_source_paths: bool,
    /// The output rules for the side files of compile units run through a
    /// wrapper ([`breakbulk_format::Resolve::side_files`]).
    #[serde(default)]
    pub side_files: Vec<breakbulk_format::rendered::OutputRule>,
    /// The variable that gives a unit the workspace wrapper runs on (its
    /// program chain names the `rustc-workspace-wrapper` tool) its
    /// package's directory in the package's tree of wrapper config files
    /// (`sources.wrapperConfig`; `variants.<v>.wrapperConfig.dirVar`).
    #[serde(default)]
    pub wrapper_config_var: Option<String>,
    /// Whether the input `build-script-hints` holds the table of
    /// build-script failure hints, which every build-script run names
    /// (`Hints::build_script_hints`).
    #[serde(default)]
    pub build_script_hints: bool,
    /// What the toolchain can do (the Nix library's `toolchainFacts`):
    /// whether rustc takes `--remap-path-scope`. Required, so a caller
    /// cannot silently get another toolchain's behaviour.
    pub capabilities: breakbulk_format::Capabilities,
}

fn default_store_dir() -> String {
    "/nix/store".into()
}

impl Toolchains {
    pub fn platform(&self, p: Platform) -> &PlatformSpec {
        match p {
            Platform::Host => &self.host,
            Platform::Target => &self.target,
        }
    }
}

/// `toolchains.json`'s `remapScope`: a `--remap-path-scope` value per kind
/// of unit; `None` remaps every scope.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemapScope {
    /// Host units (build scripts, proc macros).
    #[serde(default)]
    pub host: Option<String>,
    /// Target units other than test units.
    #[serde(default)]
    pub target: Option<String>,
    /// Test units (the plan's `test`), of either platform.
    #[serde(default)]
    pub test: Option<String>,
}

/// Env and env capture for one platform, of a toolchain spec or a package
/// override.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PlatformSpec {
    /// Names of the env variables set; the values are substituted by Nix.
    #[serde(default)]
    pub env: BTreeSet<String>,
    /// Whether an env capture exists: the platform's base capture for a
    /// toolchain spec, the package's own capture for an override.
    #[serde(default)]
    pub env_capture: bool,
}

/// `overrides.json`.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Overrides {
    /// Per package, keyed `name@version` or `name`; the versioned key wins.
    #[serde(default)]
    pub packages: BTreeMap<String, PackageOverride>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PackageOverride {
    #[serde(default)]
    pub host: PlatformSpec,
    #[serde(default)]
    pub target: PlatformSpec,
    /// `packages.<name>.buildScript.outDirRemove`, for the package's
    /// build-script runs on either platform.
    #[serde(default)]
    pub out_dir_remove: Vec<breakbulk_format::rendered::OutDirRemove>,
}

impl PackageOverride {
    pub fn platform(&self, p: Platform) -> &PlatformSpec {
        match p {
            Platform::Host => &self.host,
            Platform::Target => &self.target,
        }
    }
}

/// `roots.json`: the roots predicted from the manifests, or the explicit
/// `roots` option.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PredictedRoots {
    /// The variant's name, for stub messages.
    pub variant: String,
    pub roots: Vec<PredictedRoot>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PredictedRoot {
    /// The package name.
    pub package: String,
    /// The Cargo target name.
    pub target: String,
    pub kind: RootKind,
    pub test: bool,
    /// The platform Cargo builds it for: `host` for a target built for the
    /// build machine (a proc macro's unit tests), else `target`. Test runs
    /// in dynamic-derivation mode choose their runner and system by it at
    /// evaluation time, so a planned root of another platform is an error.
    pub platform: Platform,
    /// The target's `required-features`, for the stub message.
    #[serde(default)]
    pub required_features: Option<Vec<String>>,
}
