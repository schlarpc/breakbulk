use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo::rustc-env=NO_VALUE\n").unwrap();
}
