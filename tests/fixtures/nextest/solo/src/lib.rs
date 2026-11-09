//! Depends on no other package, so `rdeps(other)` leaves it out.
pub fn one() -> u32 {
    1
}

#[cfg(test)]
mod tests {
    #[test]
    fn solo_ok() {
        println!("solo-success-output");
        assert_eq!(super::one(), 1);
    }
}
