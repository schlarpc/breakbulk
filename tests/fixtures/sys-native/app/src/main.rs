fn main() {
    // OpenSSL's version number, from the library pkg-config found.
    let ssl = unsafe { openssl_sys::OpenSSL_version_num() };
    let major = ssl >> 28;
    println!(
        "openssl={} cm={} bg={} plain-saw={}",
        if major >= 3 { "3+" } else { "old" },
        cm_sys::answer(),
        bg_sys::answer(),
        plain::SAW,
    );
}
