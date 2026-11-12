use std::process::Command;

/// The test-time form: a test that runs Cargo on its own package.
#[test]
fn cargo_run_inner() {
    let out = Command::new(std::env::var_os("CARGO").expect("CARGO is set"))
        .args(["run", "--locked", "--quiet", "-p", "inner"])
        .output()
        .expect("running cargo");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "cargo run failed: {stderr}");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("inner says 42"), "{stdout}");
}
