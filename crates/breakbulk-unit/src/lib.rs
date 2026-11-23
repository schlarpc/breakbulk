//! Library half of `breakbulk-unit`, the builder of every compile and
//! run unit, shared with the doctest and docs builders
//! (`breakbulk-doctest`, `breakbulk-docs`).
//!
//! Kept small and nearly dependency-free (only `serde`, `serde_json` and
//! breakbulk's own `breakbulk-hints`): any change here changes every unit
//! derivation. What only doctests or docs run lives in their own crates,
//! so a change there leaves the compile and run units alone.

pub mod compile;
pub mod diag;
pub mod directives;
pub mod env;
pub mod manifest;
pub mod process;
pub mod repository_paths;
pub mod run;
pub mod spec;
pub mod splice;
#[cfg(test)]
pub(crate) mod test_util;
pub use breakbulk_hints as view_hints;

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
pub fn io_err(what: &str, path: &std::path::Path, e: std::io::Error) -> Error {
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

/// The main function of a unit builder (`breakbulk-unit`,
/// `breakbulk-doctest`, `breakbulk-docs`): reads the unit ([`read_unit`]),
/// hands it to `build`, and prints an error. A builder takes no
/// arguments; `usage` says what it does.
pub fn builder_main(
    usage: &str,
    build: impl FnOnce(spec::RenderedUnit, &env::Outer) -> Result<(), Error>,
) -> std::process::ExitCode {
    use std::process::ExitCode;
    if std::env::args().len() > 1 {
        eprintln!("{usage}");
        return ExitCode::from(2);
    }
    let outer = env::Outer::from_process();
    match read_unit(&outer).and_then(|unit| build(unit, &outer)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// The unit a builder builds: `BREAKBULK_UNIT`, or, when the derivation
/// passes it with `passAsFile`, the file `BREAKBULK_UNITPath` names.
pub fn read_unit(outer: &env::Outer) -> Result<spec::RenderedUnit, Error> {
    let (text, whence) = if let Some(path) = outer.get("BREAKBULK_UNITPath") {
        let text = std::fs::read_to_string(path)
            .map_err(|e| Error(format!("reading BREAKBULK_UNITPath {path}: {e}")))?;
        (text, format!("the file {path}"))
    } else if let Some(text) = outer.get("BREAKBULK_UNIT") {
        (text.to_owned(), "BREAKBULK_UNIT".to_owned())
    } else {
        return Err(Error::new(
            "neither BREAKBULK_UNIT nor BREAKBULK_UNITPath is set",
        ));
    };
    serde_json::from_str(&text).map_err(|e| Error(format!("invalid unit in {whence}: {e}")))
}

/// The builder of each kind of unit (`builder`, a derivation's), and the
/// error for a unit of a kind `builder` does not build.
pub fn wrong_builder(unit: &spec::RenderedUnit, builder: &str) -> Error {
    let (kind, right) = match unit {
        spec::RenderedUnit::Compile(_) => ("compile", "breakbulk-unit"),
        spec::RenderedUnit::Run(_) => ("run", "breakbulk-unit"),
        spec::RenderedUnit::Doctest(_) => ("doctest", "breakbulk-doctest"),
        spec::RenderedUnit::Docs(_) => ("docs", "breakbulk-docs"),
    };
    Error(format!(
        "{builder} was given a `{kind}` unit, which {right} builds"
    ))
}
