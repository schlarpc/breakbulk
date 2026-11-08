/// Doubles `x`. Not inlined, so its code (and debug info naming this file)
/// is in util's library, which the tests of `app` link.
#[inline(never)]
pub fn double(x: u32) -> u32 {
    x * 2
}
