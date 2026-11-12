/// A small report, the value each snapshot test checks.
pub fn render() -> String {
    ["first", "second", "third"]
        .iter()
        .enumerate()
        .map(|(i, s)| format!("{}. {s}\n", i + 1))
        .collect()
}

#[cfg(test)]
mod tests {
    // The snapshot is `src/snapshots/snaps__tests__render.snap`.
    #[test]
    fn render() {
        insta::assert_snapshot!(super::render());
    }
}
