use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo::warning=before failing\ncargo::error=and an error\n").unwrap();
    std::process::exit(3);
}
