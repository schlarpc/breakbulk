// A root-level directory, outside this virtual workspace: listed in
// extraSources.
const ASSETS: &str = include_str!(concat!(env!("BB_ASSETS"), "/data.txt"));

fn main() {
    println!(
        "vmember: {} {}",
        ASSETS.trim(),
        itoa::Buffer::new().format(3)
    );
}
