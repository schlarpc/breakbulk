mod a;

pub const DATA: &str = include_str!("data.txt");
pub const PAGE: &str = reader::page!();
pub const PROTO: &str = env!("PROTO");

pub fn answer() -> u32 {
    a::forty() + 2
}
