//! Library half of `breakbulk-unit`, the builder of every unit.
//!
//! Kept small and nearly dependency-free (only `serde` and `serde_json`):
//! any change here changes every unit derivation.

pub mod directives;
pub mod spec;
pub mod splice;

/// The file in a run's `flags` output holding its parsed directives
/// ([`directives::BuildOutput`] as JSON).
pub const DIRECTIVES_FILE: &str = "directives.json";
/// The file in a run's `flags` output holding its `links` metadata
/// ([`directives::MetadataFile`] as JSON), present when the package declares
/// `links`.
pub const METADATA_FILE: &str = "metadata.json";
