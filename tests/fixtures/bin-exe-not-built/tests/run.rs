#[test]
fn the_built_bin_runs() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_tool"))
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout), "tool\n");
}

#[test]
fn the_bin_that_was_not_built_does_not_exist() {
    assert!(!std::path::Path::new(env!("CARGO_BIN_EXE_extra")).exists());
}
