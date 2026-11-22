//! The tag grammar of sentinels, shared by the build-script stub, which
//! prints them, and the planner, which reads them back
//! (`docs/src/reference/sentinels.md`).
//!
//! A tag names one build-script run: Cargo's hash of the run unit, as it
//! appears in the run's `OUT_DIR`. Cargo writes it as lowercase hex
//! (`UnitHash`'s `Display`, `{:016x}`).

use std::path::Path;

/// The prefix of every sentinel token: `__bb_<tag>_<rest>`.
pub const PREFIX: &str = "__bb_";

/// Whether `s` is a tag: non-empty lowercase hex.
pub fn is_tag(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// `__bb_<tag>_<rest>` → (tag, rest).
pub fn split_tag(s: &str) -> Option<(&str, &str)> {
    let (tag, rest) = s.strip_prefix(PREFIX)?.split_once('_')?;
    is_tag(tag).then_some((tag, rest))
}

/// The tag of the run whose `OUT_DIR` is `out_dir`: the hash of the
/// directory holding `out`, `…/build/<pkg>-<hash>/out` (Cargo's classic
/// build-directory layout) or `…/build/<pkg>/<hash>/out` (the new one).
pub fn run_tag(out_dir: &Path) -> Option<&str> {
    if out_dir.file_name()? != "out" {
        return None;
    }
    let dir = out_dir.parent()?.file_name()?.to_str()?;
    let tag = dir.rsplit_once('-').map_or(dir, |(_, h)| h);
    is_tag(tag).then_some(tag)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags() {
        assert!(is_tag("0a1b2c3d4e5f6789"));
        assert!(!is_tag(""));
        assert!(!is_tag("0A1B"));
        assert!(!is_tag("build"));
        assert_eq!(split_tag("__bb_0a1b_cfg"), Some(("0a1b", "cfg")));
        assert_eq!(
            split_tag("__bb_0a1b_arg_bin_x"),
            Some(("0a1b", "arg_bin_x"))
        );
        assert_eq!(split_tag("__bb_xyz_cfg"), None);
        assert_eq!(split_tag("__bb_0A1B_cfg"), None);
        assert_eq!(split_tag("__bb_0a1b"), None);
    }

    #[test]
    fn run_tags() {
        fn tag(p: &str) -> Option<&str> {
            run_tag(Path::new(p))
        }
        assert_eq!(
            tag("/t/x86_64/debug/build/foo-sys-0a1b2c3d4e5f6789/out"),
            Some("0a1b2c3d4e5f6789")
        );
        assert_eq!(
            tag("/t/debug/build/foo/0a1b2c3d4e5f6789/out"),
            Some("0a1b2c3d4e5f6789")
        );
        assert_eq!(
            tag("/t/debug/build/build/0a1b2c3d4e5f6789/out"),
            Some("0a1b2c3d4e5f6789")
        );
        // A directory that is not a run's: no tag, rather than its name.
        assert_eq!(tag("/t/debug/build/foo/run/out"), None);
        assert_eq!(tag("/t/debug/build/foo-0a1b"), None);
    }
}
