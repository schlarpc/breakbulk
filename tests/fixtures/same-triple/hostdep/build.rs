// hostdep is only a build dependency, so this run is a host unit: neither
// the target spec's env, linker nor rustflags may reach it.
fn main() {
    assert!(
        std::env::var_os("BB_MARKER").is_none(),
        "the target spec's env reached a host build-script run"
    );
    let linker = std::env::var("RUSTC_LINKER").unwrap_or_default();
    assert!(
        !linker.contains("marker"),
        "the target linker reached a host build-script run: {linker}"
    );
    let flags = std::env::var("CARGO_ENCODED_RUSTFLAGS").unwrap_or_default();
    assert!(
        !flags.contains("bb_marker_flag") && !flags.contains("project_flag"),
        "target rustflags reached a host build-script run: {flags:?}"
    );
}
