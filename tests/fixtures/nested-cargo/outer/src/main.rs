use std::io::Write;

const INNER: &[u8] = include_bytes!(env!("INNER_BIN"));

/// Prints facts about the embedded binary; with an argument, also writes it
/// to that path (so a test can run it).
fn main() {
    println!(
        "outer embeds {} bytes, magic {:02x}{:02x}{:02x}{:02x}",
        INNER.len(),
        INNER[0],
        INNER[1],
        INNER[2],
        INNER[3]
    );
    if let Some(path) = std::env::args().nth(1) {
        std::fs::File::create(path)
            .and_then(|mut f| f.write_all(INNER))
            .expect("writing the inner binary");
    }
}
