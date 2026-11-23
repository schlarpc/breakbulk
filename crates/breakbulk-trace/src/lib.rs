//! What `breakbulk-shim` and `breakbulk-plan` share about a trace: the
//! records the shim writes and the planner reads ([`record`]), the names
//! they agree on ([`names`]), and rustc's command-line grammar
//! ([`rustc_args`]). The sentinel tags the stub prints are
//! `breakbulk-sentinel`'s.

pub mod record;
pub mod rustc_args;

/// The variables, file names and program names the planner sets up and the
/// shim reads.
pub mod names {
    /// The directory the shim writes its records into (required for
    /// compiles, rustdoc and stubs).
    pub const RECORD_ENV: &str = "BREAKBULK_RECORD";
    /// The real rustdoc, for the shim acting as `RUSTDOC`.
    pub const RUSTDOC_ENV: &str = "BREAKBULK_RUSTDOC";
    /// The variant's rustc wrapper, which the shim puts first in every
    /// rustc chain, where Cargo would have.
    pub const RUSTC_WRAPPER_ENV: &str = "BREAKBULK_RUSTC_WRAPPER";
    /// The `cargo metadata --format-version 1` JSON the stub reads to learn
    /// its package's targets. Default: [`METADATA_FILE`] in the record
    /// directory.
    pub const METADATA_ENV: &str = "BREAKBULK_METADATA";
    /// The default `cargo metadata` file in the record directory, which
    /// the planner does not read as a record.
    pub const METADATA_FILE: &str = "metadata.json";
    /// The file name the planner starts the shim by as the test runner of
    /// a traced `cargo test`.
    pub const TEST_RUNNER: &str = "breakbulk-test-runner";
    /// The marker beside an installed build-script stub
    /// ([`crate::record::StubMarker`]).
    pub const STUB_MARKER: &str = "breakbulk-stub.json";
    /// The variables of the planner's own protocol with the shim, which no
    /// unit keeps.
    pub const PROTOCOL_ENV: [&str; 4] = [RECORD_ENV, RUSTDOC_ENV, RUSTC_WRAPPER_ENV, METADATA_ENV];
}
