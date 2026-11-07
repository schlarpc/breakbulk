pub fn alpha() -> &'static str {
    env!("ALPHA_STAMP")
}

#[cfg(test)]
mod tests {
    // Cargo gives the test process its package's build-script `rustc-env`
    // values, and a dynamic-library path with the search paths every
    // build script of the platform printed inside its OUT_DIR (beta's).
    #[test]
    fn runtime_env() {
        assert_eq!(std::env::var("ALPHA_STAMP").as_deref(), Ok("alpha-stamp"));
        assert_eq!(super::alpha(), "alpha-stamp");
        let path = std::env::var("LD_LIBRARY_PATH").unwrap();
        assert!(
            path.split(':')
                .any(|d| std::path::Path::new(d).join("libbeta_marker.so").is_file()),
            "no libbeta_marker.so on {path}"
        );
    }
}
