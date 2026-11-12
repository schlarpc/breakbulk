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
    /// Workspace members with a clippy config tree (clippy variants): the
    /// `.clippy.toml` and `clippy.toml` files of the package directory and
    /// its ancestors up to the repository root, rooted there like source
    /// views, by directory.
    #[serde(default)]
    pub clippy_conf: BTreeSet<String>,
    /// Path packages' test-only paths (relative to the repository root),
    /// which their normal source views leave out, by directory. Only for
    /// hints ([`breakbulk_format::Resolve::source_view`]).
    #[serde(default)]
    pub test_only: BTreeMap<String, Vec<String>>,
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
    /// The `--remap-path-scope` of target compile units that end up in
    /// shipped products whose debug information is split off
    /// (`splitDebug`), e.g. `macro,diagnostics`: debug info keeps real
    /// store paths (plus `coverage` in coverage variants). `None`: every
    /// scope is remapped. Host units do not read it: they always get
    /// `macro,diagnostics`. Test harnesses (`--test`) always remap every
    /// scope, and so does every unit when rustc has no `--remap-path-scope`
    /// (`capabilities`; "Source paths at run time" in
    /// `docs/src/reference/unit-builder.md`).
    #[serde(default)]
    pub shipped_remap_scope: Option<String>,
    /// `sourcePaths = "keep"`: add no remaps of breakbulk's
    /// own, Rust or C ([`breakbulk_format::Resolve::keep_source_paths`]).
    #[serde(default)]
    pub keep_source_paths: bool,
    /// The target platform's traits that instantiation needs (the Nix
    /// library's `targetTraits.forRust`): the debuginfo side files its links
    /// write (`debugArtifacts`), which decide whether link units get a
    /// `debug` output. Required, so a
    /// caller cannot silently get another platform's behaviour.
    pub target_traits: breakbulk_format::TargetTraits,
    /// What the toolchain can do (the Nix library's `toolchainFacts`):
    /// whether rustc takes `--remap-path-scope`. Required, like
    /// `target_traits`.
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
