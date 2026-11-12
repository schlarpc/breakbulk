include!(concat!(env!("OUT_DIR"), "/squares.rs"));

// The component the greet workspace builds.
const GREET: &[u8] = include_bytes!(env!("GREET_COMPONENT"));

fn main() {
    // A component starts with the wasm magic, version 0x0d and layer 1.
    let component = GREET.starts_with(b"\0asm\x0d\x00\x01\x00");
    println!("component {component}, squares {SQUARES:?}");
}

#[cfg(test)]
mod tests {
    #[test]
    fn squares() {
        assert_eq!(super::SQUARES[3], 9);
    }
}
