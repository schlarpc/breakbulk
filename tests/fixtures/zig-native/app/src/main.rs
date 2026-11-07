fn main() {
    println!(
        "zig-native: {} sha256(abc)={} zlib={} adler32={:08x}",
        app::openssl_version().split_whitespace().take(2).collect::<Vec<_>>().join(" "),
        &app::sha256_hex(b"abc")[..8],
        app::zlib_version(),
        app::adler32(b"Wikipedia"),
    );
}
