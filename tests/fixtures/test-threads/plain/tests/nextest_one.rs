#[test]
fn nextest_one_thread() {
    if std::env::var("TT_EXPECT_NEXTEST_ONE").is_err() {
        return;
    }
    assert_eq!(std::env::var("NEXTEST_TEST_THREADS").as_deref(), Ok("1"));
}
