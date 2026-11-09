use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo::warning=new syntax\ncargo:warning=old syntax\n").unwrap();
}
