// A proc macro is a host unit: compiled without the target rustflags.
use proc_macro::TokenStream;

#[proc_macro]
pub fn assert_host_clean(_: TokenStream) -> TokenStream {
    if cfg!(bb_marker_flag) || cfg!(project_flag) {
        "compile_error!(\"target rustflags reached the proc macro's compile\");"
            .parse()
            .unwrap()
    } else {
        TokenStream::new()
    }
}
