//! Library half of `breakbulk-unit`, the builder of every unit.
//!
//! Kept small and nearly dependency-free (only `serde` and `serde_json`):
//! any change here changes every unit derivation.

pub mod compile;
pub mod diag;
pub mod directives;
pub mod doctest;
pub mod env;
pub mod manifest;
pub mod process;
pub mod run;
pub mod spec;
pub mod splice;
pub mod test_only;
#[cfg(test)]
pub(crate) mod test_util;

use std::fmt;

/// The file in a run's `flags` output holding its parsed directives
/// ([`directives::BuildOutput`] as JSON).
pub const DIRECTIVES_FILE: &str = "directives.json";
/// The file in a run's `flags` output naming its package, its `OUT_DIR`
/// and its `links` metadata ([`directives::MetadataFile`] as JSON).
pub const METADATA_FILE: &str = "metadata.json";

/// In a run's `flags`, when its script wrote files outside `OUT_DIR` (into
/// the copy of Cargo's target directory around it, #23): their paths
/// relative to the run's `out`, sorted.
pub const TARGET_FILES_FILE: &str = "target-files.json";

/// In a run's `flags`, when its script declared `rerun-if-changed` paths
/// that are not in its view: each one with its hint
/// ([`run::MissingPathEntry`] list as JSON), for the products' check.
pub const MISSING_PATHS_FILE: &str = "missing-paths.json";

/// A unit failure: the message is printed as `error: …` and the build fails.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error(pub String);

impl Error {
    pub fn new(msg: impl Into<String>) -> Error {
        Error(msg.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

impl From<splice::SpliceError> for Error {
    fn from(e: splice::SpliceError) -> Error {
        Error(e.0)
    }
}

impl From<directives::DirectiveError> for Error {
    fn from(e: directives::DirectiveError) -> Error {
        Error(e.0)
    }
}

/// Attach the path concerned to an I/O error.
pub(crate) fn io_err(what: &str, path: &std::path::Path, e: std::io::Error) -> Error {
    Error(format!("{what} {}: {e}", path.display()))
}

/// Read a run's `directives.json` from its `flags` directory.
pub fn read_directives(flags: &std::path::Path) -> Result<directives::BuildOutput, Error> {
    let p = flags.join(DIRECTIVES_FILE);
    let text = std::fs::read_to_string(&p).map_err(|e| io_err("reading", &p, e))?;
    serde_json::from_str(&text).map_err(|e| Error(format!("{}: {e}", p.display())))
}

/// Read a run's `metadata.json` from its `flags` directory.
pub fn read_metadata(flags: &std::path::Path) -> Result<directives::MetadataFile, Error> {
    let p = flags.join(METADATA_FILE);
    let text = std::fs::read_to_string(&p).map_err(|e| io_err("reading", &p, e))?;
    serde_json::from_str(&text).map_err(|e| Error(format!("{}: {e}", p.display())))
}

/// Write a value as JSON, with a final newline.
pub(crate) fn write_json<T: serde::Serialize>(
    path: &std::path::Path,
    value: &T,
) -> Result<(), Error> {
    let mut text = serde_json::to_string(value).map_err(|e| Error(e.to_string()))?;
    text.push('\n');
    std::fs::write(path, text).map_err(|e| io_err("writing", path, e))
}
