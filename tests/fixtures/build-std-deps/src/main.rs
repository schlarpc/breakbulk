use std::collections::HashMap;

fn main() {
    // std's HashMap is hashbrown, a crates.io dependency of std.
    let m: HashMap<&str, u32> = [("a", 1), ("b", 2), ("c", 3)].into_iter().collect();
    println!("hashmap has {} entries", m.len());
}
