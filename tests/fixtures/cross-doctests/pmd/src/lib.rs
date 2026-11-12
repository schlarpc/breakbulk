//! A proc macro whose doctest is built for the host and runs there.
//!
//! ```
//! assert_eq!(pmd::seven!(), 7);
//! ```

use proc_macro::TokenStream;

#[proc_macro]
pub fn seven(_: TokenStream) -> TokenStream {
    "7".parse().unwrap()
}
