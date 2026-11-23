fn main() {
    let mut buf = itoa::Buffer::new();
    println!("{} {}", buf.format(itoa::PATCHED), breakbulk_test_prevendored::VALUE);
}
