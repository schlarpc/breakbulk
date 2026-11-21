fn main() {
    println!("cargo:rerun-if-changed=proto/x.proto");
    let proto = std::fs::read_to_string("proto/x.proto").unwrap();
    println!("cargo:rustc-env=PROTO={}", proto.trim());
}
