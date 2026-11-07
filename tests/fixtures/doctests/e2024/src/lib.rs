//! Edition 2024: rustdoc merges these doctests into one binary, except the
//! `standalone_crate` one.

/// Adds one.
///
/// ```
/// assert_eq!(e2024::inc(1), 2);
/// ```
///
/// ```
/// assert_eq!(e2024::inc(41), 42);
/// ```
///
/// ```standalone_crate
/// assert_eq!(e2024::inc(0), 1);
/// ```
///
/// ```should_panic
/// e2024::inc(u32::MAX);
/// ```
pub fn inc(x: u32) -> u32 {
    x.checked_add(1).expect("overflow")
}
