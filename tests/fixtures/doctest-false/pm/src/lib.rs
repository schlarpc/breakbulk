//! Doctests are off: this block is not Rust, and running it would fail.
//!
//! ```
//! this is not Rust
//! ```

use proc_macro::TokenStream;

#[proc_macro]
pub fn answer(_: TokenStream) -> TokenStream {
    "42".parse().unwrap()
}
