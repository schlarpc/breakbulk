//! The dependency manifest in a library's `rmeta` output.
//!
//! A library unit's derivation names only its direct dependencies (see
//! `breakbulk_format::deps`). What lies below them reaches the sandbox
//! through Nix's reference scanning: every library's `rmeta` output holds
//! [`MANIFEST_FILE`], which names
//!
//! - `crates`: its own `.rmeta` file, and the crate files below it that no
//!   dependency's manifest names (proc macros it names directly);
//! - `flags`: the `flags` directories of the runs whose search paths its
//!   compile was given, minus those its dependencies' manifests name;
//! - `deps`: its direct dependencies' `rmeta` directories, the next
//!   manifests down.
//!
//! Each manifest lists only what is new at its level, so the references of
//! the whole graph grow with its edges, not with the sum of its closures.
//! A dependent walks the manifests from its own direct dependencies down
//! ([`walk`]).
//!
//! `rlib` outputs carry no manifest and no references, so fetching a
//! library's `rmeta` from a cache never fetches an `rlib`.

use std::collections::BTreeSet;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::{Error, io_err};

/// The manifest's file name inside an `rmeta` output.
pub const MANIFEST_FILE: &str = "breakbulk-deps.json";

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub crates: BTreeSet<String>,
    pub flags: BTreeSet<String>,
    pub deps: BTreeSet<String>,
}

/// Everything the manifests below a unit name.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Below {
    pub crates: BTreeSet<String>,
    pub flags: BTreeSet<String>,
}

/// Read the manifest in an `rmeta` output directory.
pub fn read(dir: &Path) -> Result<Manifest, Error> {
    let p = dir.join(MANIFEST_FILE);
    let text = std::fs::read_to_string(&p).map_err(|e| io_err("reading", &p, e))?;
    serde_json::from_str(&text).map_err(|e| Error(format!("{}: {e}", p.display())))
}

/// Walk the manifests of `dirs` and every manifest below them.
pub fn walk(dirs: &[String]) -> Result<Below, Error> {
    let mut below = Below::default();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut stack: Vec<String> = dirs.to_vec();
    while let Some(d) = stack.pop() {
        if !seen.insert(d.clone()) {
            continue;
        }
        let m = read(Path::new(&d))?;
        below.crates.extend(m.crates);
        below.flags.extend(m.flags);
        stack.extend(m.deps.into_iter().filter(|d| !seen.contains(d)));
    }
    Ok(below)
}

/// Write a unit's own manifest into its `rmeta` output directory `dir`.
pub fn write(dir: &Path, m: &Manifest) -> Result<(), Error> {
    crate::write_json(&dir.join(MANIFEST_FILE), m)
}
