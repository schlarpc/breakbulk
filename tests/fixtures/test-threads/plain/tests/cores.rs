use std::env::var;

/// With nothing set, a test run gets NIX_BUILD_CORES test threads: libtest's
/// RUST_TEST_THREADS from the direct runner, nextest's test-threads under
/// nextest, which runs each test in its own process.
#[test]
fn default_threads() {
    if var("TT_EXPECT_DEFAULT").is_err() {
        return;
    }
    let cores = var("NIX_BUILD_CORES").unwrap();
    if var("NEXTEST").is_ok() {
        assert_eq!(var("NEXTEST_TEST_THREADS").unwrap(), cores);
    } else {
        assert_eq!(var("RUST_TEST_THREADS").unwrap(), cores);
    }
}
