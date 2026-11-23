//! `breakbulk-unit`: the builder of every compile and run unit.
//!
//! Reads what to do from `BREAKBULK_UNIT` (or, when the derivation passes it
//! with `passAsFile`, from the file named by `BREAKBULK_UNITPath`) and does
//! it according to its `kind`: `compile` or `run`. Output paths come from
//! the variables Nix names after the derivation's outputs. Doctests and
//! docs have builders of their own (`breakbulk-doctest`, `breakbulk-docs`),
//! so a change to them does not change every unit.

use std::process::ExitCode;

use breakbulk_unit::spec::RenderedUnit;

const USAGE: &str = "usage: breakbulk-unit\n\n\
    Builds the compile or run unit described by $BREAKBULK_UNIT (or the file \
    $BREAKBULK_UNITPath), as its `kind` says.";

fn main() -> ExitCode {
    breakbulk_unit::builder_main(USAGE, |unit, outer| match &unit {
        RenderedUnit::Compile(c) => breakbulk_unit::compile::compile(c, outer),
        RenderedUnit::Run(r) => breakbulk_unit::run::run(r, outer),
        RenderedUnit::Doctest(_) | RenderedUnit::Docs(_) => {
            Err(breakbulk_unit::wrong_builder(&unit, "breakbulk-unit"))
        }
    })
}
