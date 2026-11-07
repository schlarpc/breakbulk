pub fn version() -> &'static str {
    env!("MYLIB_VERSION")
}
pub fn vendored() -> &'static str {
    env!("MYLIB_VENDORED")
}
