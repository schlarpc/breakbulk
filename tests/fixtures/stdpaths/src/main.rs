// Standard-library generic code instantiated here (the sort, the slice
// iterators) carries panic locations in std's own files. With the toolchain's
// rust-src component installed, rustc names them by the local copy's path.
fn main() {
    let mut v: Vec<String> = std::env::args().skip(1).collect();
    v.push("b".into());
    v.push("a".into());
    v.sort();
    let n = v.len().max(1);
    for chunk in v.chunks(n) {
        println!("{}", chunk.join(","));
    }
}
