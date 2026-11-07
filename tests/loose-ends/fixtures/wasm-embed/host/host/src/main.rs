use std::io::Write;

/// The wasm component, built for wasm32 by another workspace and embedded
/// at compile time. `UI_WASM` comes from `packages.host.env`.
static UI: &[u8] = include_bytes!(env!("UI_WASM"));

/// Prints what the embedded module is; with an argument, also writes it to
/// that path (so a check can validate it).
fn main() {
    println!("host embeds {}", util::describe(UI));
    if let Some(path) = std::env::args().nth(1) {
        std::fs::File::create(path)
            .and_then(|mut f| f.write_all(UI))
            .expect("writing the component");
    }
}
