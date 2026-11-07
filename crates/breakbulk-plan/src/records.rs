//! The records `breakbulk-shim` writes, and the `cargo metadata` JSON.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Deserialize;

use crate::{Error, bail};

/// One shim record (see `crates/breakbulk-shim/src/record.rs`).
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub mode: String,
    pub program: Vec<String>,
    pub args: Vec<String>,
    pub cwd: String,
    pub env: BTreeMap<String, String>,
    /// Compile records: every file rustc would write.
    #[serde(default)]
    pub outputs: Vec<RecordOutput>,
    /// Run records: the run's tag (the hash in its `OUT_DIR`).
    #[serde(default)]
    pub tag: Option<String>,
    /// Run records: the stub's marker file.
    #[serde(default)]
    pub stub: Option<StubMarker>,
    /// Run records: the sentinel lines the stub printed.
    #[serde(default)]
    pub printed: Vec<String>,
    /// The file the record was read from, for messages.
    #[serde(skip)]
    pub file: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RecordOutput {
    pub emit: String,
    pub path: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct StubMarker {
    pub compile: StubCompile,
}

#[derive(Clone, Debug, Deserialize)]
pub struct StubCompile {
    /// The file name of the build-script compile's link output.
    pub binary: Option<String>,
}

/// Read every record in `dir`, ordered by file name. The order carries no
/// meaning; it only makes failures reproducible.
pub fn read_records(dir: &Path) -> Result<Vec<Record>, Error> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .map_err(|e| Error(format!("reading {}: {e}", dir.display())))?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".json") && !n.starts_with('.') && n != "metadata.json")
        .collect();
    names.sort();
    names
        .into_iter()
        .map(|n| {
            let p = dir.join(&n);
            let text = std::fs::read_to_string(&p)
                .map_err(|e| Error(format!("reading {}: {e}", p.display())))?;
            let mut r: Record =
                serde_json::from_str(&text).map_err(|e| Error(format!("{}: {e}", p.display())))?;
            r.file = n;
            Ok(r)
        })
        .collect()
}

/// The parts of `cargo metadata --format-version 1` the planner reads.
#[derive(Clone, Debug, Deserialize)]
pub struct Metadata {
    pub packages: Vec<Package>,
    pub workspace_members: Vec<String>,
    pub workspace_root: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Package {
    pub id: String,
    pub name: String,
    pub version: String,
    pub source: Option<String>,
    pub manifest_path: String,
    pub targets: Vec<Target>,
    #[serde(default)]
    pub links: Option<String>,
    #[serde(default)]
    pub rust_version: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Target {
    pub name: String,
    pub kind: Vec<String>,
    pub crate_types: Vec<String>,
    pub src_path: String,
    #[serde(default)]
    pub doctest: bool,
    #[serde(default)]
    pub test: bool,
}

impl Package {
    /// The package directory: the manifest's parent.
    pub fn dir(&self) -> &str {
        self.manifest_path
            .strip_suffix("/Cargo.toml")
            .unwrap_or(&self.manifest_path)
    }

    pub fn is_path(&self) -> bool {
        self.source.is_none()
    }
}

impl Target {
    pub fn is_lib(&self) -> bool {
        !self.kind.iter().any(|k| {
            matches!(
                k.as_str(),
                "bin" | "example" | "test" | "bench" | "custom-build"
            )
        })
    }
    pub fn has_kind(&self, k: &str) -> bool {
        self.kind.iter().any(|x| x == k)
    }
}

impl Metadata {
    pub fn read(path: &Path) -> Result<Metadata, Error> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| Error(format!("reading {}: {e}", path.display())))?;
        serde_json::from_str(&text).map_err(|e| Error(format!("{}: {e}", path.display())))
    }

    pub fn package(&self, id: &str) -> Result<&Package, Error> {
        match self.packages.iter().find(|p| p.id == id) {
            Some(p) => Ok(p),
            None => bail!("package {id} is not in `cargo metadata`"),
        }
    }

    /// The package whose directory is `dir` (a `CARGO_MANIFEST_DIR`).
    pub fn package_at(&self, dir: &str) -> Result<&Package, Error> {
        let dir = dir.trim_end_matches('/');
        let canon = std::fs::canonicalize(dir).ok();
        match self.packages.iter().find(|p| {
            p.dir() == dir
                || canon.is_some()
                    && std::fs::canonicalize(p.dir()).ok().as_deref() == canon.as_deref()
        }) {
            Some(p) => Ok(p),
            None => bail!("no package in `cargo metadata` has the directory {dir}"),
        }
    }
}
