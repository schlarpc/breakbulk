fn main() {
    println!("cargo::rustc-env=HOST_VALUE={}", runtime::value(1));
}
