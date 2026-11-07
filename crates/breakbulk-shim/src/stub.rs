//! Build-script stub: installed in place of a compiled build script; when
//! Cargo runs it, it records the environment and prints sentinel directives.
//!
//! See "Sentinel directives" in docs/implementation.md.

use crate::args::RustcArgs;
use crate::{Error, record};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// Marker file written next to the stub binary. Its presence beside the
/// running executable is how the shim knows it was started as a stub.
pub const MARKER: &str = "breakbulk-stub.json";

/// Env var naming the `cargo metadata --format-version 1` JSON the stub reads
/// to learn the package's targets. Default: `$BREAKBULK_RECORD/metadata.json`.
pub const METADATA_ENV: &str = "BREAKBULK_METADATA";

/// Copies the shim to the build script's output path and writes the marker.
pub fn install(path: &Path, record_dir: &Path, rustc: &str, a: &RustcArgs) -> Result<(), Error> {
    let me = std::env::current_exe().map_err(|e| Error::new(format!("current_exe: {e}")))?;
    std::fs::copy(&me, path).map_err(|e| Error::io(path, e))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| Error::io(path, e))?;
    }
    let metadata = std::env::var_os(METADATA_ENV)
        .map(PathBuf::from)
        .unwrap_or_else(|| record_dir.join("metadata.json"));
    let marker = json!({
        "version": record::RECORD_VERSION,
        "record": record_dir.to_string_lossy(),
        "metadata": metadata.to_string_lossy(),
        "rustc": rustc,
        "compile": {
            "crateName": a.crate_name,
            "extraFilename": a.extra_filename,
            "binary": path.file_name().map(|f| f.to_string_lossy().into_owned()),
            "manifestDir": std::env::var("CARGO_MANIFEST_DIR").ok(),
            "pkgName": std::env::var("CARGO_PKG_NAME").ok(),
            "pkgVersion": std::env::var("CARGO_PKG_VERSION").ok(),
        },
    });
    let dir = path.parent().unwrap_or(Path::new("."));
    let mpath = dir.join(MARKER);
    std::fs::write(&mpath, serde_json::to_vec_pretty(&marker).unwrap()).map_err(|e| Error::io(&mpath, e))
}

/// Returns the marker if the running executable is an installed stub.
pub fn detect() -> Option<(PathBuf, Value)> {
    let mut candidates = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        candidates.push(exe);
    }
    if let Some(a0) = std::env::args_os().next() {
        candidates.push(PathBuf::from(a0));
    }
    for exe in candidates {
        let Some(dir) = exe.parent() else { continue };
        let m = dir.join(MARKER);
        if let Ok(bytes) = std::fs::read(&m) {
            if let Ok(v) = serde_json::from_slice(&bytes) {
                return Some((m, v));
            }
        }
    }
    None
}

/// The tag `R` for a build-script run, taken from its `OUT_DIR`:
/// `…/build/<pkg>-<hash>/out` gives `<hash>`; a layout with
/// `…/build/<pkg>/<hash>/out` also gives `<hash>`.
pub fn run_tag(out_dir: &Path) -> Option<String> {
    let parent = if out_dir.file_name()? == "out" {
        out_dir.parent()?
    } else {
        out_dir
    };
    let last = parent.file_name()?.to_str()?;
    let tag = last.rsplit_once('-').map_or(last, |(_, h)| h);
    (!tag.is_empty() && tag.chars().all(|c| c.is_ascii_hexdigit() || c.is_ascii_lowercase()))
        .then(|| tag.to_ascii_lowercase())
}

/// Targets of one package, as far as sentinel selection needs them.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PackageTargets {
    pub bins: Vec<String>,
    pub has_test: bool,
    pub has_bench: bool,
    pub has_example: bool,
    pub has_cdylib: bool,
}

impl PackageTargets {
    /// Finds the package whose manifest is `<manifest_dir>/Cargo.toml` in
    /// `cargo metadata` output.
    pub fn from_metadata(meta: &Value, manifest_dir: &Path) -> Option<PackageTargets> {
        let want = manifest_dir.join("Cargo.toml");
        let want_c = std::fs::canonicalize(&want).unwrap_or(want.clone());
        let pkg = meta["packages"].as_array()?.iter().find(|p| {
            p["manifest_path"].as_str().is_some_and(|m| {
                let m = Path::new(m);
                m == want || std::fs::canonicalize(m).is_ok_and(|c| c == want_c)
            })
        })?;
        let mut t = PackageTargets::default();
        for target in pkg["targets"].as_array()? {
            let kinds: Vec<&str> = target["kind"]
                .as_array()
                .map(|k| k.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            let name = target["name"].as_str().unwrap_or_default();
            for k in &kinds {
                match *k {
                    "bin" => t.bins.push(name.to_string()),
                    "test" => t.has_test = true,
                    "bench" => t.has_bench = true,
                    "example" => t.has_example = true,
                    "cdylib" => t.has_cdylib = true,
                    _ => {}
                }
            }
        }
        t.bins.sort();
        Some(t)
    }
}

/// Whether the package's `rust-version` predates the `cargo::` syntax (1.77).
pub fn needs_old_syntax(rust_version: &str) -> bool {
    let mut parts = rust_version.trim().split('.').map(|p| p.parse::<u64>().ok());
    match (parts.next().flatten(), parts.next().flatten()) {
        (Some(major), Some(minor)) => (major, minor) < (1, 77),
        (Some(major), None) => major < 1,
        _ => false,
    }
}

/// The sentinel directives for run `tag`, in a fixed order.
/// Returns `(directive key, value)` pairs.
pub fn sentinels(tag: &str, out_dir: &Path, targets: &PackageTargets, links: bool) -> Vec<(String, String)> {
    let r = tag;
    let mut v: Vec<(String, String)> = vec![
        ("rustc-cfg".into(), format!("__bb_{r}_cfg")),
        ("rustc-check-cfg".into(), format!("cfg(__bb_{r}_ccfg)")),
        ("rustc-env".into(), format!("__BB_{}_ENV=__bb_{r}_env", r.to_ascii_uppercase())),
        (
            "rustc-link-search".into(),
            format!("native={}", out_dir.join(format!("__bb_{r}_search")).display()),
        ),
        ("rustc-link-lib".into(), format!("__bb_{r}_lib")),
        ("rustc-link-arg".into(), format!("__bb_{r}_arg")),
    ];
    if !targets.bins.is_empty() {
        v.push(("rustc-link-arg-bins".into(), format!("__bb_{r}_arg_bins")));
    }
    for b in &targets.bins {
        v.push(("rustc-link-arg-bin".into(), format!("{b}=__bb_{r}_arg_bin_{b}")));
    }
    if targets.has_test {
        v.push(("rustc-link-arg-tests".into(), format!("__bb_{r}_arg_tests")));
    }
    if targets.has_example {
        v.push(("rustc-link-arg-examples".into(), format!("__bb_{r}_arg_examples")));
    }
    if targets.has_bench {
        v.push(("rustc-link-arg-benches".into(), format!("__bb_{r}_arg_benches")));
    }
    if targets.has_cdylib {
        v.push(("rustc-link-arg-cdylib".into(), format!("__bb_{r}_arg_cdylib")));
    }
    if links {
        v.push(("metadata".into(), format!("__bb={r}")));
    }
    v
}

/// Formats one directive line in the syntax the package may use.
pub fn line(key: &str, value: &str, old_syntax: bool) -> String {
    match (old_syntax, key) {
        // In the old syntax, metadata is any unreserved key.
        (true, "metadata") => format!("cargo:{value}"),
        (true, _) => format!("cargo:{key}={value}"),
        (false, _) => format!("cargo::{key}={value}"),
    }
}

/// Runs stub mode.
pub fn run(marker_path: &Path, marker: &Value) -> Result<(), Error> {
    let record_dir = PathBuf::from(
        marker["record"]
            .as_str()
            .ok_or_else(|| Error::new(format!("{}: no record dir", marker_path.display())))?,
    );
    let out_dir = PathBuf::from(
        std::env::var_os("OUT_DIR").ok_or_else(|| Error::new("build-script stub: OUT_DIR not set"))?,
    );
    let tag = run_tag(&out_dir)
        .ok_or_else(|| Error::new(format!("build-script stub: no run tag in OUT_DIR {}", out_dir.display())))?;
    let manifest_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap_or_default());
    let meta_path = PathBuf::from(marker["metadata"].as_str().unwrap_or_default());
    let meta: Value = std::fs::read(&meta_path)
        .map_err(|e| Error::io(&meta_path, e))
        .and_then(|b| {
            serde_json::from_slice(&b).map_err(|e| Error::new(format!("{}: {e}", meta_path.display())))
        })?;
    let targets = PackageTargets::from_metadata(&meta, &manifest_dir).ok_or_else(|| {
        Error::new(format!(
            "build-script stub: package at {} not found in {}",
            manifest_dir.display(),
            meta_path.display()
        ))
    })?;
    let links = std::env::var("CARGO_MANIFEST_LINKS").is_ok_and(|l| !l.is_empty());
    let old_syntax = needs_old_syntax(&std::env::var("CARGO_PKG_RUST_VERSION").unwrap_or_default());
    let directives = sentinels(&tag, &out_dir, &targets, links);
    let lines: Vec<String> = directives.iter().map(|(k, v)| line(k, v, old_syntax)).collect();

    let argv: Vec<String> = std::env::args().collect();
    let mut rec = record::base("run", &argv[..1], &argv[1..]);
    rec.insert("tag".into(), json!(tag));
    rec.insert("stub".into(), marker.clone());
    rec.insert("printed".into(), json!(lines));
    record::write(&record_dir, "run", &tag, rec).map_err(|e| Error::new(format!("writing record: {e}")))?;

    for l in &lines {
        println!("{l}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags() {
        assert_eq!(run_tag(Path::new("/t/x86_64/debug/build/foo-sys-0a1b2c3d4e5f6789/out")).as_deref(), Some("0a1b2c3d4e5f6789"));
        assert_eq!(run_tag(Path::new("/t/debug/build/foo/0a1b2c3d4e5f6789/out")).as_deref(), Some("0a1b2c3d4e5f6789"));
    }

    #[test]
    fn syntax() {
        assert!(needs_old_syntax("1.70"));
        assert!(needs_old_syntax("1.76.0"));
        assert!(!needs_old_syntax("1.77"));
        assert!(!needs_old_syntax(""));
        assert_eq!(line("metadata", "__bb=ab", true), "cargo:__bb=ab");
        assert_eq!(line("rustc-cfg", "x", false), "cargo::rustc-cfg=x");
    }

    #[test]
    fn sentinel_set() {
        let t = PackageTargets { bins: vec!["app".into()], has_test: true, ..Default::default() };
        let s = sentinels("ab", Path::new("/o"), &t, true);
        let keys: Vec<&str> = s.iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(
            keys,
            ["rustc-cfg", "rustc-check-cfg", "rustc-env", "rustc-link-search", "rustc-link-lib",
             "rustc-link-arg", "rustc-link-arg-bins", "rustc-link-arg-bin", "rustc-link-arg-tests", "metadata"]
        );
        assert_eq!(s[7].1, "app=__bb_ab_arg_bin_app");
        assert_eq!(s[3].1, "native=/o/__bb_ab_search");
    }
}
