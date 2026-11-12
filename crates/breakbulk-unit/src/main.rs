//! `breakbulk-unit unit`: the builder of every unit derivation.
//!
//! Reads the unit from `BREAKBULK_UNIT` (or, when the derivation passes it
//! with `passAsFile`, from the file named by `BREAKBULK_UNITPath`) and runs it
//! in `compile` or `run` mode according to its `kind`. Output paths come from
//! the variables Nix names after the derivation's outputs.
//!
//! `breakbulk-unit test-run-hints SPEC LOG` prints the hints for a failed
//! test run's log ([`breakbulk_unit::view_hints::test_run_main`]).

use std::process::ExitCode;

use breakbulk_unit::Error;
use breakbulk_unit::env::Outer;
use breakbulk_unit::spec::RenderedUnit;

const USAGE: &str = "usage: breakbulk-unit unit|doctest\n       \
    breakbulk-unit test-run-hints SPEC LOG\n\n\
    Builds the unit (or runs the doctests) described by $BREAKBULK_UNIT (or the file $BREAKBULK_UNITPath).";

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
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["doctest"] {
        return breakbulk_unit::doctest::main();
    }
    if args.first().map(String::as_str) == Some("test-run-hints") {
        return breakbulk_unit::view_hints::test_run_main(&args[1..]);
    }
    if args != ["unit"] {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    }
    let outer = Outer::from_process();
    let result = read_unit(&outer).and_then(|unit| match &unit {
        RenderedUnit::Compile(c) => breakbulk_unit::compile::compile(c, &outer),
        RenderedUnit::Run(r) => breakbulk_unit::run::run(r, &outer),
    });
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}
