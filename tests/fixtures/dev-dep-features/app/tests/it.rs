#[test]
fn integration_test_sees_the_feature() {
    assert!(feat::extra_enabled());
}

/// The bin Cargo builds for integration tests is built with the test
/// plan's features too.
#[test]
fn bin_built_for_tests_has_the_feature() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_app"))
        .output()
        .unwrap();
    assert_eq!(String::from_utf8(out.stdout).unwrap(), "extra=true\n");
}
