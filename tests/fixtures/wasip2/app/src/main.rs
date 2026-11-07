fn main() {
    let args = std::env::args().count();
    // Monotonic clock and env: WASI imports the component must carry.
    let _ = std::time::Instant::now();
    println!("{} args={args}", app::greet(42, "p2"));
}
