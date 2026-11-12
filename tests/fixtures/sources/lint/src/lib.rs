pub fn answer() -> u32 {
    42
}

#[cfg(test)]
mod tests {
    #[test]
    fn matches_snapshot() {
        assert_eq!(include_str!("snapshots/answer.snap").trim(), super::answer().to_string());
    }
}
