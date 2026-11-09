use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo::metadata=k=v\n").unwrap();
}
