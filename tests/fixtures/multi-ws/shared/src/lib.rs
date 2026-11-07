pub fn fmt(n: u64) -> String {
    let mut b = itoa::Buffer::new();
    let cfg = if cfg!(shared_cfg) { "+cfg" } else { "" };
    format!("shared:{}{}", b.format(n), cfg)
}
