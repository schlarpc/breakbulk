fn main() {
    println!("cargo::rustc-cfg=never_reached");
    std::process::abort();
}
