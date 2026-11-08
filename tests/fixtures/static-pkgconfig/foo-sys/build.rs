fn main() {
    // Static or dynamic is pkg-config-rs's choice: static with
    // PKG_CONFIG_ALL_STATIC (or BBFOO_STATIC) when libbbfoo.a exists.
    pkg_config::probe_library("bbfoo").unwrap();
}
