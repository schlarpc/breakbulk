use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo::error=crlf\r\n").unwrap();
}
