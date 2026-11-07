/// OpenSSL's major version, from the library pkg-config found.
pub fn openssl_major() -> u64 {
    (unsafe { openssl_sys::OpenSSL_version_num() } as u64) >> 28
}

/// Compresses and decompresses through libzstd.
pub fn zstd_roundtrip(data: &[u8]) -> Vec<u8> {
    use zstd_sys::*;
    unsafe {
        let bound = ZSTD_compressBound(data.len());
        let mut c = vec![0u8; bound];
        let n = ZSTD_compress(c.as_mut_ptr().cast(), bound, data.as_ptr().cast(), data.len(), 3);
        assert_eq!(ZSTD_isError(n), 0);
        let mut d = vec![0u8; data.len()];
        let m = ZSTD_decompress(d.as_mut_ptr().cast(), d.len(), c.as_ptr().cast(), n);
        assert_eq!(ZSTD_isError(m), 0);
        d.truncate(m);
        d
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn roundtrip() {
        let data = b"breakbulk riscv64 breakbulk riscv64 breakbulk riscv64".repeat(10);
        assert_eq!(super::zstd_roundtrip(&data), data);
    }

    #[test]
    fn openssl_is_3() {
        assert!(super::openssl_major() >= 3);
    }

    #[test]
    fn arch_is_riscv64() {
        assert!(cfg!(target_arch = "riscv64"));
    }
}
