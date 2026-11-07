pub fn base() -> &'static str {
    if cfg!(gitbase_cfg) {
        "base+cfg"
    } else {
        "base"
    }
}
