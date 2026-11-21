// LAZY_FILE names a file in a tree fetched with `builtins.fetchGit`
// (tests/lazy-strings sets it through the package's `env`).
const DATA: &str = include_str!(env!("LAZY_FILE"));

fn main() {
    print!("{DATA}");
}
