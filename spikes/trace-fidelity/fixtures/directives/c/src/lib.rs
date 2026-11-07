/// Doc example.
///
/// ```
/// assert_eq!(c::c(), "b_sys");
/// ```
pub fn c() -> &'static str { let _ = env!("REAL_C_ENV"); b_sys::b() }
