include!("../common/build_common.rs");
fn main() {
    emit(&Pkg { name: "c", old_syntax: false, links: false, bins: &[], tests: true, examples: true, benches: true, cdylib: true, link_lib: true });
}
