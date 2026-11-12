#[cfg(feature = "fast")]
fn answer() -> String {
    itoa::Buffer::new().format(42).to_owned()
}

#[cfg(not(feature = "fast"))]
fn answer() -> String {
    42.to_string()
}

fn main() {
    println!("od {} fast={}", answer(), cfg!(feature = "fast"));
}
