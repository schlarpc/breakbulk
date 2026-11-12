#[cfg(all(feature = "a", feature = "b"))]
compile_error!("features `a` and `b` are mutually exclusive");

fn main() {
    let flavor = if cfg!(feature = "a") { "a" } else { "b" };
    println!("ef {flavor}");
}
