//! `breakbulk-unit`: the builder of every unit, doctest and docs derivation.
//!
//! Reads what to do from `BREAKBULK_UNIT` (or, when the derivation passes it
//! with `passAsFile`, from the file named by `BREAKBULK_UNITPath`) and does
//! it according to its `kind`: `compile`, `run`, `doctest` or `docs`. Output
//! paths come from the variables Nix names after the derivation's outputs.

use std::process::ExitCode;

use breakbulk_unit::Error;
use breakbulk_unit::env::Outer;
use breakbulk_unit::spec::RenderedUnit;

const USAGE: &str = "usage: breakbulk-unit\n\n\
    Builds the unit, runs the doctests, or writes the documentation described by \
    $BREAKBULK_UNIT (or the file $BREAKBULK_UNITPath), as its `kind` says.";

fn read_unit(outer: &Outer) -> Result<RenderedUnit, Error> {
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

fn main() -> ExitCode {
    if std::env::args().len() > 1 {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    }
    let outer = Outer::from_process();
    let result = read_unit(&outer).and_then(|unit| match &unit {
        RenderedUnit::Compile(c) => breakbulk_unit::compile::compile(c, &outer),
        RenderedUnit::Run(r) => breakbulk_unit::run::run(r, &outer),
        RenderedUnit::Doctest(d) => breakbulk_unit::doctest::doctest(d, &outer),
        RenderedUnit::Docs(d) => breakbulk_unit::docs::docs(d, &outer),
    });
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}
