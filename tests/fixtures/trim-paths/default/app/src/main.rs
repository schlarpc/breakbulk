fn main() {
    std::panic::set_hook(Box::new(|info| {
        let loc = info.location().expect("a location");
        println!("panicked at {}:{}", loc.file(), loc.line());
    }));
    println!("main is {}", file!());
    println!("shared is {}", shared::where_am_i());
    println!("generated is {}", shared::generated_at());
    println!("{}", shared::format(42));
    let r = std::panic::catch_unwind(|| shared::boom(7));
    assert!(r.is_err());
}
