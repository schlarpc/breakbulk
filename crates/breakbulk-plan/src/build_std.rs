//! `-Zbuild-std` ("build-std" in `docs/implementation.md`).
//!
//! Cargo resolves the standard library's own workspace
//! (`<sysroot>/lib/rustlib/src/rust/library`, with its own `Cargo.lock`)
//! with the project's source configuration (cargo `src/compiler/
//! standard_lib.rs`, `resolve_std`: `Workspace::new` with the same
//! `GlobalContext`). Its crates.io dependencies (`hashbrown`, `libc`,
//! `rustc-literal-escaper`, …) are not in the project's lockfile, so the
//! planner's offline vendor directory lacks them. The `rust-src` component
//! ships them already vendored, with checksums (`library/vendor`, the
//! directory source that `library/.cargo/config.toml` points at).
//!
//! The planner therefore gives Cargo one crates.io directory that holds the
//! project's vendored crates and, for every name and version the project
//! does not have, the toolchain's. Units of the standard library's
//! packages name toolchain store paths, which instantiation treats like any
//! other toolchain path.

use std::path::{Path, PathBuf};

use crate::{Error, bail};

/// The merged crates.io directory and the toolchain's `library`.
#[derive(Clone, Debug)]
pub struct StdVendor {
    /// `<scratch>/std-vendor`: one symlink per crate.
    pub dir: String,
    /// `<sysroot>/lib/rustlib/src/rust/library`.
    pub library: String,
    /// A config file that points crates.io (or its replacement) at `dir`.
    pub config: String,
}

/// Whether the project's config files turn on `-Zbuild-std`
/// (`[unstable] build-std`).
pub fn uses_build_std(files: &[PathBuf]) -> Result<bool, Error> {
    for f in files {
        let text = std::fs::read_to_string(f)
            .map_err(|e| Error(format!("reading {}: {e}", f.display())))?;
        let table: toml::Table =
            toml::from_str(&text).map_err(|e| Error(format!("{}: {e}", f.display())))?;
        if table
            .get("unstable")
            .and_then(|u| u.as_table())
            .is_some_and(|u| u.contains_key("build-std"))
        {
            return Ok(true);
        }
    }
    Ok(false)
}

/// The crates.io replacement in the planner's `--config` files: the source
/// name crates.io is replaced with, and its directory.
fn crates_io_directory(configs: &[String]) -> Result<Option<(String, String)>, Error> {
    for c in configs {
        let p = Path::new(c);
        if !p.is_file() {
            continue;
        }
        let text = std::fs::read_to_string(p).map_err(|e| Error(format!("reading {c}: {e}")))?;
        let Ok(table) = toml::from_str::<toml::Table>(&text) else {
            continue;
        };
        let sources = table.get("source").and_then(|s| s.as_table());
        let Some(name) = sources
            .and_then(|s| s.get("crates-io"))
            .and_then(|c| c.get("replace-with"))
            .and_then(|r| r.as_str())
        else {
            continue;
        };
        let Some(dir) = sources
            .and_then(|s| s.get(name))
            .and_then(|s| s.get("directory"))
            .and_then(|d| d.as_str())
        else {
            bail!("{c}: crates.io is replaced with `{name}`, which is no directory source");
        };
        return Ok(Some((name.to_owned(), dir.to_owned())));
    }
    Ok(None)
}

fn symlink(target: &Path, link: &Path) -> Result<(), Error> {
    std::os::unix::fs::symlink(target, link)
        .map_err(|e| Error(format!("linking {}: {e}", link.display())))
}

fn entries(dir: &Path) -> Result<Vec<std::ffi::OsString>, Error> {
    let mut v: Vec<_> = std::fs::read_dir(dir)
        .map_err(|e| Error(format!("reading {}: {e}", dir.display())))?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name())
        .filter(|n| !n.to_string_lossy().starts_with('.'))
        .collect();
    v.sort();
    Ok(v)
}

fn toml_str(s: &str) -> String {
    serde_json::to_string(s).expect("strings serialize")
}

/// Build the merged crates.io directory under `scratch` and the config
/// file pointing Cargo at it. `None` when the sysroot has no `rust-src`
/// (Cargo then fails with its own hint to add it).
pub fn prepare(
    sysroot: &Path,
    configs: &[String],
    scratch: &Path,
) -> Result<Option<StdVendor>, Error> {
    let library = sysroot.join("lib/rustlib/src/rust/library");
    if !library.join("Cargo.lock").is_file() {
        return Ok(None);
    }
    let vendor = library.join("vendor");
    if !vendor.is_dir() {
        bail!(
            "-Zbuild-std: the toolchain's rust-src has no vendored dependencies ({})",
            vendor.display()
        );
    }
    let dir = scratch.join("std-vendor");
    std::fs::create_dir_all(&dir).map_err(|e| Error(format!("creating {}: {e}", dir.display())))?;
    let replaced = crates_io_directory(configs)?;
    if let Some((_, project)) = &replaced {
        for n in entries(Path::new(project))? {
            symlink(&Path::new(project).join(&n), &dir.join(&n))?;
        }
    }
    for n in entries(&vendor)? {
        if !dir.join(&n).symlink_metadata().is_ok() {
            symlink(&vendor.join(&n), &dir.join(&n))?;
        }
    }
    let d = toml_str(&dir.display().to_string());
    let text = match &replaced {
        Some((name, _)) => format!("[source.{}]\ndirectory = {d}\n", toml_str(name)),
        None => format!(
            "[source.crates-io]\nreplace-with = \"breakbulk-std\"\n\n\
             [source.breakbulk-std]\ndirectory = {d}\n"
        ),
    };
    let config = scratch.join("std-vendor.toml");
    std::fs::write(&config, text)
        .map_err(|e| Error(format!("writing {}: {e}", config.display())))?;
    Ok(Some(StdVendor {
        dir: dir.display().to_string(),
        library: library.display().to_string(),
        config: config.display().to_string(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merged_directory() {
        let t = std::env::temp_dir().join(format!("bb-build-std-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&t);
        let sysroot = t.join("sysroot");
        let lib = sysroot.join("lib/rustlib/src/rust/library");
        for c in ["hashbrown-0.1.0", "libc-0.2.0"] {
            std::fs::create_dir_all(lib.join("vendor").join(c)).unwrap();
        }
        std::fs::write(lib.join("Cargo.lock"), "").unwrap();
        let project = t.join("vendor/abc");
        std::fs::create_dir_all(project.join("libc-0.2.0")).unwrap();
        let cfg = t.join("vendor.toml");
        std::fs::write(
            &cfg,
            format!(
                "[source.crates-io]\nreplace-with = \"breakbulk-abc\"\n[source.breakbulk-abc]\ndirectory = {}\n",
                toml_str(&project.display().to_string())
            ),
        )
        .unwrap();
        let scratch = t.join("scratch");
        std::fs::create_dir_all(&scratch).unwrap();
        let v = prepare(&sysroot, &[cfg.display().to_string()], &scratch)
            .unwrap()
            .unwrap();
        let dir = Path::new(&v.dir);
        // The project's own copy wins; the toolchain's fills the gaps.
        assert_eq!(
            std::fs::read_link(dir.join("libc-0.2.0")).unwrap(),
            project.join("libc-0.2.0")
        );
        assert_eq!(
            std::fs::read_link(dir.join("hashbrown-0.1.0")).unwrap(),
            lib.join("vendor/hashbrown-0.1.0")
        );
        let text = std::fs::read_to_string(&v.config).unwrap();
        assert!(
            text.starts_with("[source.\"breakbulk-abc\"]\ndirectory = "),
            "{text}"
        );
        // No crates.io replacement in the project: one of its own.
        let scratch2 = t.join("scratch2");
        std::fs::create_dir_all(&scratch2).unwrap();
        let v = prepare(&sysroot, &[], &scratch2).unwrap().unwrap();
        let text = std::fs::read_to_string(&v.config).unwrap();
        assert!(text.contains("replace-with = \"breakbulk-std\""), "{text}");
        std::fs::remove_dir_all(&t).unwrap();
    }
}
