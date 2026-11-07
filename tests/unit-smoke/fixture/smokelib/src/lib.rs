include!(concat!(env!("OUT_DIR"), "/gen.rs"));

/// Set by the build script through `rustc-env`.
pub const SMOKE_ENV: &str = env!("SMOKE_ENV");

/// True only when the build script's `rustc-cfg` reached this crate.
pub fn cfg_reached() -> bool {
    cfg!(smoke_cfg)
}
