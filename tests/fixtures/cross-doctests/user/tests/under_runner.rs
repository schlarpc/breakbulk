// An integration test: built for the target, run under its runner.
#[test]
fn seven_under_the_runner() {
    assert_eq!(user::seven(), pmd::seven!());
}
