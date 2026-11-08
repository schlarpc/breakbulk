/// The features this copy of `shared` was built with, and the set's length.
///
/// ```
/// assert_eq!(shared::features(), "none 4");
/// ```
pub fn features() -> String {
    let set = match (cfg!(feature = "fa"), cfg!(feature = "fb")) {
        (true, true) => "fa+fb",
        (true, false) => "fa",
        (false, true) => "fb",
        (false, false) => "none",
    };
    let mut buf = itoa::Buffer::new();
    format!("{set} {}", buf.format(set.len()))
}

#[cfg(test)]
mod tests {
    #[test]
    fn no_features_of_its_own() {
        assert_eq!(super::features(), "none 4");
    }
}
