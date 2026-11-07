// Run by wasm-bindgen-test-runner (Node.js by default; the preset's
// browser = "chromium" runs them in headless Chromium).
use wasm_bindgen_test::wasm_bindgen_test;

#[wasm_bindgen_test]
fn digest() {
    assert_eq!(
        ui::digest_hex("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}

#[wasm_bindgen_test]
fn random() {
    let a = ui::random_bytes(32);
    let b = ui::random_bytes(32);
    assert_eq!(a.len(), 32);
    assert_ne!(a, b);
}
