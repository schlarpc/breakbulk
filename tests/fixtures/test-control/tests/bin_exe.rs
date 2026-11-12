#[test]
fn runs_the_bin() {
    let bin = env!("CARGO_BIN_EXE_ctl");
    println!("CARGO_BIN_EXE_ctl={bin}");
    let out = std::process::Command::new(bin).output().unwrap();
    assert!(out.status.success());
    assert_eq!(String::from_utf8(out.stdout).unwrap().trim(), "ctl says hi 42");
}

// The bin's file has the name Cargo uplifts it to: its target name, hyphen
// kept (its crate name is ctl_extra), with no hash. A program that prints
// its own name sees that name in argv[0] and in current_exe().
#[test]
fn bin_has_its_cargo_name() {
    let bin = env!("CARGO_BIN_EXE_ctl-extra");
    let want = format!("ctl-extra{}", std::env::consts::EXE_SUFFIX);
    let file = std::path::Path::new(bin).file_name().unwrap();
    assert_eq!(file.to_str(), Some(want.as_str()));
    let out = std::process::Command::new(bin).output().unwrap();
    assert!(out.status.success());
    let printed = String::from_utf8(out.stdout).unwrap();
    assert_eq!(printed.lines().collect::<Vec<_>>(), [&want, &want]);
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
    // A name with a hyphen, which a shell cannot `export`.
    assert_eq!(
        std::env::var("CARGO_BIN_EXE_ctl-extra").as_deref(),
        Ok(env!("CARGO_BIN_EXE_ctl-extra"))
    );
}
