use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo::rustc-link-arg-examples=-v\n").unwrap();
}
