//! `breakbulk-doctest`: the builder of doctest derivations ([`doctest`]),
//! over `breakbulk-unit`'s library. A binary of its own, so that a change
//! to how doctests run does not change the builder of every unit.

use std::process::ExitCode;

use breakbulk_unit::spec::RenderedUnit;

mod doctest;

const USAGE: &str = "usage: breakbulk-doctest\n\n\
    Runs the doctests described by $BREAKBULK_UNIT (or the file $BREAKBULK_UNITPath).";

fn main() -> ExitCode {
    breakbulk_unit::builder_main(USAGE, |unit, outer| match &unit {
        RenderedUnit::Doctest(d) => doctest::doctest(d, outer),
        _ => Err(breakbulk_unit::wrong_builder(&unit, "breakbulk-doctest")),
    })
}
