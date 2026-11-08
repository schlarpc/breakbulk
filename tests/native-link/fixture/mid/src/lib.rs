/// The C library's answer, described.
///
/// ```
/// assert!(mid::describe().starts_with("the answer is "));
/// ```
pub fn describe() -> String {
    format!("the answer is {}", foo_sys::answer())
}
