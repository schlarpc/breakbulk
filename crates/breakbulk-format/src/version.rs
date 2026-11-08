//! Rust and Cargo releases, and the features breakbulk gates on them. One
//! parse and one table of named gates for every program; the Nix library's
//! counterpart is `util.rustVersion` (`lib/util.nix`).

/// A release's major and minor version, from `rustc -vV`'s release line
/// (`1.99.0 (b940084d7 2026-09-28)`, `1.101.0-nightly (…)`) or `cargo -V`
/// without `cargo ` (the same shape). Channel suffixes are ignored: a
/// nightly 1.101 is 1.101.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct RustVersion {
    pub major: u64,
    pub minor: u64,
}

impl RustVersion {
    pub const fn new(major: u64, minor: u64) -> Self {
        RustVersion { major, minor }
    }

    /// The first two numbers of `s`, or `None` without two.
    pub fn parse(s: &str) -> Option<RustVersion> {
        let mut parts = s
            .split(|c: char| !c.is_ascii_digit())
            .filter(|p| !p.is_empty())
            .map(|p| p.parse::<u64>().unwrap_or(0));
        match (parts.next(), parts.next()) {
            (Some(major), Some(minor)) => Some(RustVersion { major, minor }),
            _ => None,
        }
    }

    /// Whether `s` names this release or a later one (false when `s` names
    /// none).
    pub fn reached_by(self, s: &str) -> bool {
        RustVersion::parse(s).is_some_and(|v| v >= self)
    }
}

/// rustc's `--remap-path-scope`: stable since 1.95.
pub const REMAP_PATH_SCOPE: RustVersion = RustVersion::new(1, 95);

/// Cargo's `trim-paths` profile setting: stable from Cargo 1.101 (nightly
/// 1.101 included); a hard error before.
pub const TRIM_PATHS: RustVersion = RustVersion::new(1, 101);

/// Whether a `cargo -V` or `rustc -vV` release is a nightly or a
/// development build, whose unstable features Cargo allows.
pub fn is_nightly(version: &str) -> bool {
    version.contains("-nightly") || version.contains("-dev")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_gates() {
        assert_eq!(
            RustVersion::parse("1.99.0 (b940084d7 2026-09-28)"),
            Some(RustVersion::new(1, 99))
        );
        assert_eq!(RustVersion::parse(""), None);
        assert!(REMAP_PATH_SCOPE.reached_by("1.95.0 (abc 2026-01-01)"));
        assert!(REMAP_PATH_SCOPE.reached_by("1.101.0-nightly (abc 2026-10-01)"));
        assert!(!REMAP_PATH_SCOPE.reached_by("1.94.0"));
        assert!(!REMAP_PATH_SCOPE.reached_by(""));
        assert!(!TRIM_PATHS.reached_by("1.99.0 (abc 2026-09-01)"));
        assert!(!TRIM_PATHS.reached_by("1.100.0-nightly (abc 2026-09-01)"));
        assert!(TRIM_PATHS.reached_by("1.101.0-nightly (3c747ea3e 2026-11-03)"));
        assert!(TRIM_PATHS.reached_by("1.101.0"));
        assert!(TRIM_PATHS.reached_by("1.102.1"));
        assert!(TRIM_PATHS.reached_by("2.0.0"));
        assert!(!TRIM_PATHS.reached_by(""));
        assert!(is_nightly("1.101.0-nightly (3c747ea3e 2026-11-03)"));
        assert!(is_nightly("1.100.0-dev"));
        assert!(!is_nightly("1.99.0 (b940084d7 2026-09-28)"));
    }
}
