fn main() {
    let mut b = itoa::Buffer::new();
    println!("app-a {} {} {}", shared::fmt(7), inner::name(), b.format(libc::EXIT_FAILURE));
}
