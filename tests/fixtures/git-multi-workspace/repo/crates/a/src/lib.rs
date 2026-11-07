pub fn info() -> String {
    format!(
        "a {} readme={} license-file={} b={}",
        env!("CARGO_PKG_VERSION"),
        env!("CARGO_PKG_README"),
        env!("CARGO_PKG_LICENSE_FILE"),
        b::value()
    )
}
