#![no_std]
#![no_main]

use core::ffi::c_void;

/// The UEFI entry point rustc's target spec names (`efi_main`). Returns
/// EFI_SUCCESS when the library's greeting has the expected length.
#[unsafe(export_name = "efi_main")]
pub extern "efiapi" fn efi_main(_image: *mut c_void, _system_table: *mut c_void) -> usize {
    let g = core::hint::black_box(greet::GREETING);
    if g.len() == greet::expected_len() { 0 } else { 1 }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}
