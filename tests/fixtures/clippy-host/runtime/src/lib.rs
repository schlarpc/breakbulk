// Without `app_unstable`, `n` is unused.
#[cfg(app_unstable)]
pub fn value(n: u32) -> u32 {
    n + 1
}

#[cfg(not(app_unstable))]
pub fn value(n: u32) -> u32 {
    1
}
