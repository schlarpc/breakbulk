include!(concat!(env!("OUT_DIR"), "/gen.rs"));

/// Set by the build script through `rustc-env`.
pub const SMOKE_ENV: &str = env!("SMOKE_ENV");

/// True only when the build script's `rustc-cfg` reached this crate.
pub fn cfg_reached() -> bool {
    cfg!(smoke_cfg)
}

unsafe extern "C" {
    fn smoke_c_answer() -> std::ffi::c_int;
}

/// From the C library the build script compiled (`rustc-link-lib`).
pub fn c_answer() -> i32 {
    unsafe { smoke_c_answer() }
}
