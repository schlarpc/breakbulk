use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo::error=boom\ncargo::warning=and a warning\n").unwrap();
}
