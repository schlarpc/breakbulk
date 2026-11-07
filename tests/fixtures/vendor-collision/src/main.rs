fn main() {
    let mut a = itoa::Buffer::new();
    let mut b = itoa_git::Buffer::new();
    cfg_if::cfg_if! {
        if #[cfg(unix)] { let n = 42u32; } else { let n = 7u32; }
    }
    assert_eq!(a.format(n), b.format(n));
    println!("ok {}", a.format(n));
}
