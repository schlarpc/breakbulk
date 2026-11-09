use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo::unknown-key=1\n").unwrap();
}
