//! Tests that pass only on a retry. Attempts share CARGO_TARGET_TMPDIR, so
//! a marker file tells the second attempt from the first.
use std::path::PathBuf;

fn first_attempt(name: &str) -> bool {
    let marker = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("{name}.tried"));
    if marker.exists() {
        false
    } else {
        std::fs::write(&marker, "").unwrap();
        true
    }
}

/// Fails on its first attempt; `retries` in .config/nextest.toml reruns it.
#[test]
fn flaky_once() {
    assert!(!first_attempt("flaky_once"), "first attempt fails");
}

/// Hangs on its first attempt; the slow-timeout's terminate-after kills it
/// and the retry passes.
#[test]
fn hangs_once() {
    if first_attempt("hangs_once") {
        std::thread::sleep(std::time::Duration::from_secs(600));
    }
}

/// Always fails. The default filter leaves it out.
#[test]
fn excluded_always_fails() {
    panic!("the default filter should have excluded this test");
}

/// The environment nextest gives the process: package values from the
/// synthesized cargo metadata, cwd, and what the test run set before
/// starting nextest.
#[test]
fn runtime_env() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    assert_eq!(std::path::Path::new(&dir), std::env::current_dir().unwrap());
    assert!(std::path::Path::new("Cargo.toml").exists());
    assert_eq!(std::env::var("CARGO_PKG_NAME").unwrap(), "nx");
    assert_eq!(std::env::var("CARGO_PKG_VERSION").unwrap(), "0.3.1");
    assert_eq!(std::env::var("CARGO_PKG_VERSION_MINOR").unwrap(), "3");
    assert_eq!(std::env::var("CARGO_PKG_AUTHORS").unwrap(), "A <a@example.com>:B");
    assert_eq!(std::env::var("CARGO_PKG_DESCRIPTION").unwrap(), "nextest fixture");
    assert_eq!(std::env::var("NEXTEST").unwrap(), "1");
    if std::env::var_os("NX_EXPECT_NIX").is_some() {
        assert_eq!(std::env::var("NX_FROM_TEST_ENV").unwrap(), "yes");
        assert_eq!(std::env::var("NEXTEST_PROFILE").unwrap(), "ci");
    }
}
