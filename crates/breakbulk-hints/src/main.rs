//! `breakbulk-hints SPEC LOG`: the hints for a failed test run's log
//! ([`breakbulk_hints::main`]).

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    breakbulk_hints::main(&args)
}
