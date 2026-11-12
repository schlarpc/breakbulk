#[test]
fn runs_bin() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_greeter"))
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "greeter failed: {stderr}");
    assert_eq!(String::from_utf8_lossy(&out.stdout), "greet=42\n");
}
