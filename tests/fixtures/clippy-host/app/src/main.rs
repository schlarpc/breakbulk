// The build script's copy of `runtime` and the binary's.
fn main() {
    println!("host={} target={}", env!("HOST_VALUE"), runtime::value(1));
}
