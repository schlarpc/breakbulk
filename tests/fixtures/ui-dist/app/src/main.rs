/// `ui`'s wasm-bindgen output for wasm32, embedded at compile time.
/// `UI_DIST` (the product) and `GIT_REV` come from `packages.app.env`.
static UI_WASM: &[u8] = include_bytes!(concat!(env!("UI_DIST"), "/pkg/ui_bg.wasm"));
static UI_JS: &str = include_str!(concat!(env!("UI_DIST"), "/pkg/ui.js"));

fn main() {
    println!(
        "app {} embeds {} bytes of wasm, magic {}, glue exports greet: {}",
        env!("GIT_REV"),
        UI_WASM.len(),
        UI_WASM.starts_with(b"\0asm"),
        UI_JS.contains("greet")
    );
}
