use proc_macro::TokenStream;

/// `pub const FOUND: &str`: this crate's name in the caller's Cargo.toml.
#[proc_macro]
pub fn found(_: TokenStream) -> TokenStream {
    let name = match find_crate::find_crate(|s| s == "mac-fc") {
        Ok(p) => p.name,
        Err(e) => {
            return format!("compile_error!({:?});", format!("find-crate: {e}"))
                .parse()
                .unwrap()
        }
    };
    format!("pub const FOUND: &str = {name:?};").parse().unwrap()
}
