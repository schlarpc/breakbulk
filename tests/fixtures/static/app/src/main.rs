unsafe extern "C" {
    fn mix(a: i32, b: i32) -> i32;
}

fn mixed(a: i32, b: i32) -> i32 {
    unsafe { mix(a, b) }
}

fn main() {
    let threads: Vec<_> = (0..2).map(|i| std::thread::spawn(move || mixed(i, 6))).collect();
    let sum: i32 = threads.into_iter().map(|t| t.join().unwrap()).sum();
    println!("static ok: mix(6,7)={} threads={sum}", mixed(6, 7));
}

#[cfg(test)]
mod tests {
    #[test]
    fn c_code_links() {
        // "6-7" has 3 characters.
        assert_eq!(super::mixed(6, 7), 45);
    }
}
