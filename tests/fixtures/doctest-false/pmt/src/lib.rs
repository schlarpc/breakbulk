//! A proc macro with tests and doctests, which Cargo runs for the host.
//!
//! ```
//! assert_eq!(pmt::seven!(), 7);
//! ```

use proc_macro::TokenStream;

#[proc_macro]
pub fn seven(_: TokenStream) -> TokenStream {
    "7".parse().unwrap()
}

#[cfg(test)]
mod tests {
    #[test]
    fn host_test() {
        assert_eq!(2 + 2, 4);
    }
}
