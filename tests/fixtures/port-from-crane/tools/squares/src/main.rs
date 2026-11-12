// Needs a nightly: the never type.
#![feature(never_type)]

fn squares() -> Result<[u32; 5], !> {
    Ok([0, 1, 4, 9, 16])
}

fn main() {
    let Ok(s) = squares();
    println!("pub const SQUARES: [u32; 5] = {s:?};");
}
