unsafe extern "C" {
    fn cross_lto_mix(x: u32) -> u32;
}

/// The Rust caller: with cross-language LTO the C function is inlined here.
#[inline(never)]
#[unsafe(no_mangle)]
pub extern "C" fn cross_lto_caller(x: u32) -> u32 {
    unsafe { cross_lto_mix(x) }.wrapping_add(1)
}

fn main() {
    let x = std::env::args().count() as u32;
    println!("cross-lto: {:08x}", cross_lto_caller(x));
}
