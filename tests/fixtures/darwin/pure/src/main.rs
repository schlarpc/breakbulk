use std::collections::BTreeMap;

fn tally(words: &[&str]) -> BTreeMap<String, usize> {
    let mut m = BTreeMap::new();
    for w in words {
        *m.entry(w.to_string()).or_insert(0) += 1;
    }
    m
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let n = args.len();
    let t = std::thread::spawn(move || {
        let words: Vec<&str> = args.iter().map(String::as_str).collect();
        tally(&words).len()
    })
    .join()
    .unwrap();
    println!("pure: {t} distinct of {n}");
}

#[cfg(test)]
mod tests {
    #[test]
    fn tally_counts() {
        assert_eq!(super::tally(&["a", "b", "a"])["a"], 2);
    }
}
