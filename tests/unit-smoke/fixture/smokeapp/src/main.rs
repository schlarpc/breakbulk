fn main() {
    assert!(smokelib::cfg_reached(), "rustc-cfg did not reach smokelib");
    println!("smoke ok: {} {}", smokelib::SMOKE_ENV, smokelib::GENERATED);
}
