//! An example that reads a fixture in `tests/` at compile time, as Cargo
//! allows.

fn main() {
    println!("{}", include_str!("../tests/fixtures/input.txt").trim());
}
