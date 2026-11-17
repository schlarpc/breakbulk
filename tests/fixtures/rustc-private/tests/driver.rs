#![feature(rustc_private)]

extern crate rustc_driver;
extern crate rustc_span;

#[test]
fn edition_from_the_driver() {
    assert_eq!(rustc_span::edition::Edition::Edition2021.to_string(), "2021");
}
