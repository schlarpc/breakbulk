use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo:some-key=1\ncargo:warning=old syntax\n").unwrap();
}
