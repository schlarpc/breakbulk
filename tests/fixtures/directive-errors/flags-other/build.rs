use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo::rustc-flags=-lfoo -Cbar\n").unwrap();
}
