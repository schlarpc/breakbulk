use std::io::Write;

fn main() {
    std::io::stdout().write_all(b"cargo::rustc-env=RUSTC_BOOTSTRAP=1\n").unwrap();
}
