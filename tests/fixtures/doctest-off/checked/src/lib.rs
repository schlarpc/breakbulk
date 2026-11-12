/// Passes only with `DOCTEST_ENV=yes` in the doctest run's environment.
///
/// ```
/// assert_eq!(std::env::var("DOCTEST_ENV").as_deref(), Ok("yes"));
/// assert_eq!(checked::one(), 1);
/// ```
pub fn one() -> u32 {
    1
}

/// Fails; the doctest run's arguments skip it.
///
/// ```
/// panic!("skipped_by_args should not run");
/// ```
pub fn skipped_by_args() {}

#[cfg(test)]
mod tests {
    #[test]
    fn one() {
        assert_eq!(super::one(), 1);
    }
}
