include!("../common/build_common.rs");
fn main() {
    emit(&Pkg { name: "oldsyn", old_syntax: true, links: true, bins: &[], tests: false, examples: false, benches: false, cdylib: false, link_lib: true });
}
