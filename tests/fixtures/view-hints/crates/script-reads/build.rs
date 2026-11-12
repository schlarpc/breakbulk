//! Reads a file outside its package without declaring it.

fn main() {
    let p = "../../shared/data.txt";
    let data = std::fs::read_to_string(p).unwrap_or_else(|e| panic!("reading {p}: {e}"));
    println!("cargo::rustc-env=DATA={}", data.trim());
}
