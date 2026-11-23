//! `breakbulk-docs`: the builder of a doc plan's docs derivation
//! ([`docs`]), over `breakbulk-unit`'s library. A binary of its own, so
//! that a change to how docs are written does not change the builder of
//! every unit.

use std::process::ExitCode;

use breakbulk_unit::spec::RenderedUnit;

mod docs;

const USAGE: &str = "usage: breakbulk-docs\n\n\
    Writes the documentation described by $BREAKBULK_UNIT (or the file \
    $BREAKBULK_UNITPath).";

fn main() -> ExitCode {
    breakbulk_unit::builder_main(USAGE, |unit, outer| match &unit {
        RenderedUnit::Docs(d) => docs::docs(d, outer),
        _ => Err(breakbulk_unit::wrong_builder(&unit, "breakbulk-docs")),
    })
}
