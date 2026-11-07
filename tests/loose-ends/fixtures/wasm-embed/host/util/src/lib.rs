/// What a wasm binary is, from its preamble: `\0asm`, then a version and a
/// layer (0 for a core module, 1 for a component).
pub fn describe(bytes: &[u8]) -> String {
    match bytes {
        [0, b'a', b's', b'm', _, _, 0, 0, ..] => format!("a core module of {} bytes", bytes.len()),
        [0, b'a', b's', b'm', _, _, 1, 0, ..] => format!("a component of {} bytes", bytes.len()),
        _ => "no wasm".to_owned(),
    }
}
