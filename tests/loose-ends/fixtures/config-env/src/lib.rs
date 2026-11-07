//! The project's `[env]` config reaches compiles and test processes.
//!
//! ```
//! // Doctests run in rustdoc's process, which Cargo gives `[env]`.
//! assert_eq!(std::env::var("BB_PLAIN").unwrap(), "plain-value");
//! assert_eq!(config_env::PLAIN_AT_COMPILE, "plain-value");
//! ```

/// `BB_PLAIN` as rustc saw it.
pub const PLAIN_AT_COMPILE: &str = env!("BB_PLAIN");
/// `BB_REL` as rustc saw it: an absolute path.
pub const REL_AT_COMPILE: &str = env!("BB_REL");
/// `HOME` as rustc saw it (forced).
pub const HOME_AT_COMPILE: &str = env!("HOME");
/// `PATH` as rustc saw it (not forced: Cargo's own).
pub const PATH_AT_COMPILE: Option<&str> = option_env!("PATH");

/// The file `BB_REL` names, read at compile time.
pub fn greeting() -> &'static str {
    include_str!(env!("BB_REL"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn unit_test_sees_env() {
        assert_eq!(std::env::var("BB_PLAIN").unwrap(), "plain-value");
        assert_eq!(super::greeting(), "hello from data\n");
    }
}
