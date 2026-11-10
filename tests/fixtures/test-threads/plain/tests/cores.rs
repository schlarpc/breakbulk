use std::env::var;

/// With nothing set, a test run gets NIX_BUILD_CORES test threads, under
/// libtest and under nextest.
#[test]
fn default_threads() {
    if var("TT_EXPECT_DEFAULT").is_err() {
        return;
    }
    let cores = var("NIX_BUILD_CORES").unwrap();
    assert_eq!(var("RUST_TEST_THREADS").unwrap(), cores);
    if var("NEXTEST").is_ok() {
        assert_eq!(var("NEXTEST_TEST_THREADS").unwrap(), cores);
    }
}
