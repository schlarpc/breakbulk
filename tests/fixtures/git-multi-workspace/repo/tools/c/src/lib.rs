pub fn info() -> String {
    format!(
        "c {} readme={} license={} description={} d={}",
        env!("CARGO_PKG_VERSION"),
        env!("CARGO_PKG_README"),
        env!("CARGO_PKG_LICENSE"),
        env!("CARGO_PKG_DESCRIPTION"),
        d::value()
    )
}
