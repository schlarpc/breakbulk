/// Which features are on, and the build script's value from `hostdep`.
pub fn describe() -> String {
    format!(
        "x={} y={} host={}",
        cfg!(feature = "x"),
        cfg!(feature = "y"),
        hostdep::FROM_BUILD
    )
}

/// Clippy's `len_zero` lint fires here; the strict clippy variant denies it.
pub fn is_empty_list(v: &[u8]) -> bool {
    v.len() == 0
}

#[cfg(test)]
mod tests {
    #[test]
    fn describes() {
        assert!(super::describe().contains("host=7"));
        assert!(super::is_empty_list(&[]));
    }
}
