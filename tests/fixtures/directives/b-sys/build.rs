include!("../common/build_common.rs");
fn main() {
    emit(&Pkg { name: "b-sys", old_syntax: false, links: true, bins: &[], tests: false, examples: false, benches: false, cdylib: false, link_lib: true });
}
