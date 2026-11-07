fn main() {
    assert!(smokelib::cfg_reached(), "rustc-cfg did not reach smokelib");
    println!(
        "smoke ok: {} {} c={}",
        smokelib::SMOKE_ENV,
        smokelib::GENERATED,
        smokelib::c_answer()
    );
}
