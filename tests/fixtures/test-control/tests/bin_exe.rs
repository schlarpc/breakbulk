#[test]
fn runs_the_bin() {
    let bin = env!("CARGO_BIN_EXE_ctl");
    println!("CARGO_BIN_EXE_ctl={bin}");
    let out = std::process::Command::new(bin).output().unwrap();
    assert!(out.status.success());
    assert_eq!(String::from_utf8(out.stdout).unwrap().trim(), "ctl says hi 42");
}
