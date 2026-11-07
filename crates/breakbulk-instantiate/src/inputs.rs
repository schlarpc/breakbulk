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
    /// The `--remap-path-scope` of compile units that end up in shipped
    /// products whose debug information is split off (`splitDebug`), e.g.
    /// `macro,diagnostics`: debug info keeps real store paths (plus
    /// `coverage` in coverage variants, which host units leave out: they are
    /// not instrumented). `None`: every scope is remapped. Test harnesses (`--test`) always remap every scope,
    /// and so does every unit when rustc is older than 1.95 ("Source paths
    /// at run time" in `docs/implementation.md`).
    #[serde(default)]
    pub shipped_remap_scope: Option<String>,
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
    /// The repository-wide `strictSources`.
    #[serde(default)]
    pub strict_sources: bool,
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
    #[serde(default)]
    pub strict_sources: Option<bool>,
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
    /// The target's `required-features`, for the stub message.
    #[serde(default)]
    pub required_features: Option<Vec<String>>,
}
