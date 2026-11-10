#[test]
fn one_thread() {
    assert_eq!(std::env::var("RUST_TEST_THREADS").as_deref(), Ok("1"));
}
