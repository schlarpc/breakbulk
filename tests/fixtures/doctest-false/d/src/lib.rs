/// Doubles.
///
/// ```
/// assert_eq!(d::double(21), 42);
/// assert_eq!(env!("D_FROM_BUILD"), "from-build-script");
/// ```
pub fn double(x: u32) -> u32 {
    x * 2
}
