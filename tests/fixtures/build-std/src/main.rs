#![no_std]
#![no_main]

/// A value the linked image must keep (checked in the ELF).
#[unsafe(no_mangle)]
pub static BB_MAGIC: [u8; 8] = *b"bb-bare!";

#[unsafe(no_mangle)]
pub extern "C" fn _start() -> ! {
    // A 128-bit division: compiler_builtins, built from source.
    let x = core::hint::black_box(1u128 << 100) / core::hint::black_box(3u128);
    core::hint::black_box(x);
    loop {
        core::hint::spin_loop();
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}
