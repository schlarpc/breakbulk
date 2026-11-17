use std::path::PathBuf;

/// The repository root: the parent of the nearest `target` directory
/// above the running binary.
pub fn root_path() -> PathBuf {
    let exe = std::env::current_exe().unwrap();
    let target = exe
        .ancestors()
        .find(|p| p.file_name().is_some_and(|n| n == "target"))
        .unwrap_or_else(|| panic!("no `target` directory above {}", exe.display()));
    target.parent().unwrap().to_path_buf()
}

#[cfg(test)]
mod tests {
    #[test]
    fn finds_the_repository() {
        let marker = super::root_path().join("repo-marker.txt");
        assert_eq!(
            std::fs::read_to_string(marker).unwrap(),
            "the repository root\n"
        );
    }
}
