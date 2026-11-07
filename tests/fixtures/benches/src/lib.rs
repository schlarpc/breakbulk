/// The n-th Fibonacci number.
pub fn fib(n: u64) -> u64 {
    if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}

#[cfg(test)]
mod tests {
    #[test]
    fn small() {
        assert_eq!(super::fib(10), 55);
    }
}
