//! A bench without the libtest harness: it reads `testdata/` (in
//! `test.sourceScope` in the checks) at compile time.

fn main() {
    assert_eq!(
        include_str!("../testdata/more.txt").trim(),
        proto::answer().to_string()
    );
    println!("unharnessed: ok");
}
