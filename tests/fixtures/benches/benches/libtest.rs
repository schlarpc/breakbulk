// A bench target with the libtest harness. `#[bench]` is nightly-only, so on
// stable it holds a test, which `--test` (the smoke check) runs.
#[test]
fn fib_works() {
    assert_eq!(bencher::fib(20), 6765);
}
