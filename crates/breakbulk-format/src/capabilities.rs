//! What the toolchain can do, as the Nix library decides it
//! (`toolchainFacts.of`'s `capabilities`, `lib/toolchain-facts.nix`;
//! "Toolchain capabilities" in `docs/implementation.md`). One source of
//! truth: the Nix library's table or probe, overridable per toolchain
//! (`workspaces.<ws>.toolchain.capabilities`) for a forked or patched
//! compiler. No breakbulk program reads a Rust or Cargo version to decide
//! a feature. The planner gets them as `--capabilities <file>`,
//! breakbulk-instantiate as `toolchains.json`'s `capabilities`; both are
//! this type's JSON.

use serde::{Deserialize, Serialize};

/// Every field is required, so a caller cannot silently get another
/// toolchain's behaviour.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Capabilities {
    /// rustc takes `--remap-path-scope` (stable since 1.95). Without it,
    /// every unit remaps every scope ("Source paths at run time").
    pub remap_path_scope: bool,
    /// Cargo has the `trim-paths` profile setting (stable from Cargo 1.101,
    /// nightly 1.101 included). The planner then turns it on unless the
    /// project declares it or `cargoTrimPaths` says otherwise ("trim-paths").
    pub trim_paths: bool,
    /// Cargo allows unstable features (a nightly or development build):
    /// recorded in the plan for build-script directives that differ there.
    pub nightly: bool,
}

impl Capabilities {
    /// Read a capabilities JSON file.
    pub fn read(path: &str) -> Result<Capabilities, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("reading {path}: {e}"))?;
        serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_shape() {
        let c: Capabilities =
            serde_json::from_str(r#"{"remapPathScope":true,"trimPaths":false,"nightly":true}"#)
                .unwrap();
        assert_eq!(
            c,
            Capabilities {
                remap_path_scope: true,
                trim_paths: false,
                nightly: true
            }
        );
        // Every field is required, and an unknown one is an error.
        assert!(serde_json::from_str::<Capabilities>(r#"{"remapPathScope":true}"#).is_err());
        assert!(
            serde_json::from_str::<Capabilities>(
                r#"{"remapPathScope":true,"trimPaths":false,"nightly":true,"other":true}"#
            )
            .is_err()
        );
    }
}
