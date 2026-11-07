use wasm_bindgen::prelude::*;

/// SHA-256 with ring, whose C and assembly parts are compiled by clang for
/// wasm32.
#[wasm_bindgen]
pub fn digest_hex(input: &str) -> String {
    let d = ring::digest::digest(&ring::digest::SHA256, input.as_bytes());
    d.as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

/// Random bytes through getrandom's `wasm_js` backend (crypto.getRandomValues).
#[wasm_bindgen]
pub fn random_bytes(n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    getrandom::fill(&mut v).expect("getrandom");
    v
}
