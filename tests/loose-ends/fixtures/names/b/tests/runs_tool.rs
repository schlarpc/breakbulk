// CARGO_BIN_EXE_tool is this package's `tool`, not a's.
#[test]
fn own_tool() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_tool"))
        .output()
        .expect("CARGO_BIN_EXE_tool runs");
    assert_eq!(String::from_utf8_lossy(&out.stdout), "tool of b\n");
}
