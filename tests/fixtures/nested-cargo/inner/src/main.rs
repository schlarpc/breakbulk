fn main() {
    let mut buf = itoa::Buffer::new();
    // `nested_cfg` comes only from rustflags the nested Cargo inherits.
    println!(
        "inner says {}, nested_cfg {}",
        buf.format(42u32),
        cfg!(nested_cfg)
    );
}
