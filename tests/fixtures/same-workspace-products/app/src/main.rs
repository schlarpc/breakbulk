use std::io::Write;

/// `tool`'s output, from the build script.
static FROM_TOOL: &str = include_str!(concat!(env!("OUT_DIR"), "/from-tool.txt"));
/// `tool`'s binary, embedded at compile time. `TOOL_BIN` comes from
/// `packages.app.env`.
static TOOL: &[u8] = include_bytes!(env!("TOOL_BIN"));

extern "C" {
    fn shared_answer() -> u32;
}

/// Prints what came from each product; with an argument, also writes the
/// embedded binary to that path (so a check can run it).
fn main() {
    println!("build script ran: {}", FROM_TOOL.trim());
    println!("shared says {}", unsafe { shared_answer() });
    println!("embeds {} bytes, elf {}", TOOL.len(), TOOL.starts_with(b"\x7fELF"));
    if let Some(path) = std::env::args().nth(1) {
        std::fs::File::create(path)
            .and_then(|mut f| f.write_all(TOOL))
            .expect("writing the embedded tool");
    }
}
