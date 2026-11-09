use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo::error=b\xffd\n").unwrap();
}
