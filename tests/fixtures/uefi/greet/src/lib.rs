#![no_std]

pub const GREETING: &str = "hello from breakbulk on UEFI";

#[inline(never)]
pub fn expected_len() -> usize {
    GREETING.len()
}
