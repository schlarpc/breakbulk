//! A library whose doctest is built for the target and runs under its
//! runner.
//!
//! ```
//! assert_eq!(user::seven(), 7);
//! ```

pub fn seven() -> u32 {
    pmd::seven!()
}
