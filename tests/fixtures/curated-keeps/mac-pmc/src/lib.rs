use proc_macro::TokenStream;
use proc_macro_crate::{crate_name, FoundCrate};

/// `pub const FOUND: &str`: this crate's name in the caller's Cargo.toml.
#[proc_macro]
pub fn found(_: TokenStream) -> TokenStream {
    let name = match crate_name("mac-pmc") {
        Ok(FoundCrate::Name(n)) => n,
        Ok(FoundCrate::Itself) => "itself".to_owned(),
        Err(e) => {
            return format!("compile_error!({:?});", format!("proc-macro-crate: {e}"))
                .parse()
                .unwrap()
        }
    };
    format!("pub const FOUND: &str = {name:?};").parse().unwrap()
}
