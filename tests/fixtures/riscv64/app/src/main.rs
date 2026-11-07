fn main() {
    let data = b"hello riscv64".repeat(4);
    let ok = app::zstd_roundtrip(&data) == data;
    println!(
        "arch={} openssl={} zstd={}",
        std::env::consts::ARCH,
        if app::openssl_major() >= 3 { "3+" } else { "old" },
        if ok { "ok" } else { "bad" },
    );
}
