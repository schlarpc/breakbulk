pub fn helper() -> u32 {
    if cfg!(helper_cfg) { 7 } else { 0 }
}
