//! Doctests that breakbulk runs as `cargo test --doc` does.
//!
//! ```
//! // A dev-dependency is visible to doctests.
//! assert_eq!(helper::triple(dd::double(7)), 42);
//! ```

/// Doubles.
///
/// ```
/// assert_eq!(dd::double(2), 4);
/// ```
///
/// ```
/// // The build script's rustc-env reaches doctests.
/// assert_eq!(env!("DD_FROM_BUILD"), "from-build-script");
/// ```
///
/// ```compile_fail
/// let x: u32 = "not a number";
/// ```
///
/// ```no_run
/// loop {}
/// ```
///
/// ```ignore
/// this is not Rust
/// ```
pub fn double(x: u32) -> u32 {
    x * 2
}

/// Halves an even number.
///
/// ```should_panic
/// dd::checked_half(3);
/// ```
pub fn checked_half(x: u32) -> u32 {
    assert!(x % 2 == 0, "odd");
    x / 2
}

/// Only present when the build script's cfg reached the crate.
///
/// ```
/// assert!(dd::cfg_on());
/// ```
#[cfg(dd_cfg)]
pub fn cfg_on() -> bool {
    true
}
