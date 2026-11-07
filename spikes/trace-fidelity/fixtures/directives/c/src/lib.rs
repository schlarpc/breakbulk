/// Doc example.
///
/// ```
/// assert_eq!(c::c(), "a_sys");
/// ```
pub fn c() -> &'static str { let _ = env!("REAL_C_ENV"); let _ = tiny::t(); b_sys::b() }
