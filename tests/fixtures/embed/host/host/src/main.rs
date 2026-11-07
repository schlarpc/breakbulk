use std::io::Write;

/// Prints facts about the embedded binary; with an argument, also writes it
/// to that path (so a test can run it).
fn main() {
    let bytes = embedder::PAYLOAD;
    println!(
        "{} embeds {} bytes, magic {:02x}{:02x}{:02x}{:02x}",
        other::NAME,
        bytes.len(),
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3]
    );
    if let Some(path) = std::env::args().nth(1) {
        std::fs::File::create(path)
            .and_then(|mut f| f.write_all(bytes))
            .expect("writing the payload");
    }
}
