include!("../common/build_common.rs");
fn main() {
    assert_eq!(hostdep::h(), 1);
    emit(&Pkg { name: "app", old_syntax: false, links: false, bins: &["app", "app-tool"], tests: false, examples: false, benches: false, cdylib: false, link_lib: true });
}
