use std::env::var_os;
use std::path::{Path, PathBuf};

/// The user cache directory, as the `dirs` crate finds it on Linux:
/// `$XDG_CACHE_HOME`, else `$HOME/.cache`.
pub fn cache_dir() -> PathBuf {
    match var_os("XDG_CACHE_HOME").filter(|v| !v.is_empty()) {
        Some(d) => PathBuf::from(d),
        None => home().join(".cache"),
    }
}

fn home() -> PathBuf {
    PathBuf::from(var_os("HOME").expect("HOME is set"))
}

/// Write a file named `name` under `$HOME` and under the user cache
/// directory, and read both back.
///
/// ```
/// th::write_home_and_cache("doctest");
/// ```
pub fn write_home_and_cache(name: &str) {
    let home = home();
    if var_os("TH_EXPECT_NIX").is_some() {
        let tmp = var_os("TMPDIR").expect("TMPDIR is set");
        assert!(
            home.starts_with(&tmp),
            "HOME {} is not in {tmp:?}",
            home.display()
        );
        let entries: Vec<_> = std::fs::read_dir(&home)
            .unwrap_or_else(|e| panic!("cannot read HOME {}: {e}", home.display()))
            .collect();
        assert!(entries.is_empty(), "HOME {} is not empty", home.display());
        assert!(var_os("XDG_CACHE_HOME").is_none(), "XDG_CACHE_HOME is set");
    }
    write(&home.join(".config/th"), name);
    write(&cache_dir().join("th"), name);
}

fn write(dir: &Path, name: &str) {
    std::fs::create_dir_all(dir).unwrap_or_else(|e| panic!("cannot create {}: {e}", dir.display()));
    let file = dir.join(name);
    std::fs::write(&file, name).unwrap_or_else(|e| panic!("cannot write {}: {e}", file.display()));
    assert_eq!(std::fs::read_to_string(&file).unwrap(), name);
}
