#[test]
fn runs_the_bin() {
    let bin = env!("CARGO_BIN_EXE_ctl");
    println!("CARGO_BIN_EXE_ctl={bin}");
    let out = std::process::Command::new(bin).output().unwrap();
    assert!(out.status.success());
    assert_eq!(String::from_utf8(out.stdout).unwrap().trim(), "ctl says hi 42");
}

// Cargo also sets CARGO_BIN_EXE_<name> on the test process (cargo 0.97.0,
// `ops/cargo_test.rs`, the `unit_output` env from `artifact::get_env`);
// assert_cmd's `Command::cargo_bin` reads it at run time.
#[test]
fn bin_exe_at_run_time() {
    assert_eq!(
        std::env::var("CARGO_BIN_EXE_ctl").as_deref(),
        Ok(env!("CARGO_BIN_EXE_ctl"))
    );
}
