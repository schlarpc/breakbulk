fn main() {
    std::panic::set_hook(Box::new(|info| {
        let loc = info.location().expect("a location");
        println!("panicked at {}:{}", loc.file(), loc.line());
    }));
    println!("dep is {}", dep::where_am_i());
    println!("{}", dep::format(42));
    let r = std::panic::catch_unwind(|| dep::boom(7));
    assert!(r.is_err());
}
