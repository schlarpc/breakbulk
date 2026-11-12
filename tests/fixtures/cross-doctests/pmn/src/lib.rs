//! A proc macro whose unit tests run on the host through nextest.

use proc_macro::TokenStream;

#[proc_macro]
pub fn eight(_: TokenStream) -> TokenStream {
    "8".parse().unwrap()
}

#[cfg(test)]
mod tests {
    #[test]
    fn runs_on_the_host_under_nextest() {
        assert_eq!(1 + 7, 8);
    }
}
