/// OpenSSL's version string, from the library pkg-config found.
pub fn openssl_version() -> String {
    let p = unsafe { openssl_sys::OpenSSL_version(openssl_sys::OPENSSL_VERSION) };
    unsafe { std::ffi::CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

/// A SHA-256 through libcrypto, as hex.
pub fn sha256_hex(data: &[u8]) -> String {
    let mut md = [0u8; 32];
    unsafe { openssl_sys::SHA256(data.as_ptr(), data.len(), md.as_mut_ptr()) };
    md.iter().map(|b| format!("{b:02x}")).collect()
}

/// zlib's version string.
pub fn zlib_version() -> String {
    let p = unsafe { libz_sys::zlibVersion() };
    unsafe { std::ffi::CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

/// The adler32 of `data` through libz.
pub fn adler32(data: &[u8]) -> u64 {
    unsafe { libz_sys::adler32(1, data.as_ptr(), data.len() as _) as u64 }
}

#[cfg(test)]
mod tests {
    #[test]
    fn sha256() {
        assert_eq!(
            super::sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn adler32() {
        assert_eq!(super::adler32(b"Wikipedia"), 0x11E60398);
    }

    #[test]
    fn openssl_is_3() {
        assert!(super::openssl_version().starts_with("OpenSSL 3."));
    }
}
