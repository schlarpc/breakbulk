include!("../common/build_common.rs");
fn main() {
    emit(&Pkg { name: "pm", old_syntax: false, links: false, bins: &[], tests: false, examples: false, benches: false, cdylib: false, link_lib: true });
}
