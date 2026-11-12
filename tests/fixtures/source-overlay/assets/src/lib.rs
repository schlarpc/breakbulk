/// The files under `ui/dist`, relative to this package, embedded at
/// compile time. Without a product placed there, only the placeholder.
#[derive(rust_embed::Embed)]
#[folder = "ui/dist"]
pub struct Ui;

#[cfg(test)]
mod tests {
    #[test]
    fn has_the_wasm() {
        let wasm = super::Ui::get("pkg/ui_bg.wasm").expect("pkg/ui_bg.wasm is embedded");
        assert!(wasm.data.starts_with(b"\0asm"));
    }
}
