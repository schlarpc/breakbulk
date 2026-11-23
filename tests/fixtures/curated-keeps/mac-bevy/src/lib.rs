use bevy_macro_utils::BevyManifest;
use proc_macro::TokenStream;
use quote::ToTokens;

/// `pub const FOUND: &str`: this crate's path as the caller's Cargo.toml
/// names it. bevy_macro_utils panics when the file is missing.
#[proc_macro]
pub fn found(_: TokenStream) -> TokenStream {
    let path = BevyManifest::shared(|m| m.get_path("mac-bevy"));
    let name = path.to_token_stream().to_string();
    format!("pub const FOUND: &str = {name:?};").parse().unwrap()
}
