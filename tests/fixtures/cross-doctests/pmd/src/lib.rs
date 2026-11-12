//! A proc macro whose doctest and unit tests are built for the host and
//! run there.
//!
//! ```
//! assert_eq!(pmd::seven!(), 7);
//! ```

use proc_macro::TokenStream;

#[proc_macro]
pub fn seven(_: TokenStream) -> TokenStream {
    "7".parse().unwrap()
}

#[cfg(test)]
mod tests {
    #[test]
    fn runs_on_the_host() {
        assert_eq!(1 + 6, 7);
    }
}
