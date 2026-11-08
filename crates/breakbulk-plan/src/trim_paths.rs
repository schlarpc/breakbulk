//! Whether the planner turns Cargo's `trim-paths` on ("trim-paths" in
//! `docs/implementation.md`, decision 121).
//!
//! A profile setting passed with `--config` replaces the project's own, so
//! the planner passes one only when the project declares none. It does not
//! copy Cargo's profile merging: it reads the workspace root's
//! `Cargo.toml` and the project's `.cargo/config.toml` (or `.cargo/config`)
//! files from the workspace directory up, and any `trim-paths` key under
//! `[profile]` in any of them (a profile, its `build-override`, or a
//! `package.<spec>` override, whatever the profile and value) counts as
//! declared. A file that does not parse is a warning and counts as
//! declaring nothing, so the dev shell, which uses the same rule, still
//! opens while a manifest is broken (decision 135).

use std::path::{Path, PathBuf};

use crate::Error;

/// `cargoTrimPaths`: `--trim-paths auto|on|off`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    /// `null`: on when Cargo has the setting (1.101 and later) unless the
    /// project declares `trim-paths` anywhere.
    #[default]
    Auto,
    /// `true`: always on (the project's own setting is replaced); a Cargo
    /// without the setting is an error.
    On,
    /// `false`: never turned on by breakbulk (also `sourcePaths = "keep"`).
    /// A project that sets it itself still gets Cargo's remaps.
    Off,
}

impl Mode {
    pub fn parse(s: &str) -> Option<Mode> {
        match s {
            "auto" => Some(Mode::Auto),
            "on" => Some(Mode::On),
            "off" => Some(Mode::Off),
            _ => None,
        }
    }
}

/// Where the project declares `trim-paths`, and the files that could not be
/// read.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Declared {
    /// `<file>: profile.<name>[.package.<spec>|.build-override].trim-paths`.
    pub places: Vec<String>,
    pub warnings: Vec<String>,
}

/// The files the rule reads, for the workspace directory `ws_dir`: its
/// `Cargo.toml`, then every `.cargo/config.toml` and `.cargo/config` from
/// `ws_dir` up to `/` (both when both exist).
pub fn files(ws_dir: &Path) -> Vec<PathBuf> {
    let mut files = vec![ws_dir.join("Cargo.toml")];
    for d in ws_dir.ancestors() {
        for name in ["config.toml", "config"] {
            let p = d.join(".cargo").join(name);
            if p.is_file() {
                files.push(p);
            }
        }
    }
    files
}

/// Read [`files`] for `trim-paths` keys.
pub fn declared(ws_dir: &Path) -> Declared {
    let mut d = Declared::default();
    for f in files(ws_dir) {
        let text = match std::fs::read_to_string(&f) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => {
                d.warnings.push(format!(
                    "could not read {} ({e}); treating it as not setting trim-paths",
                    f.display()
                ));
                continue;
            }
        };
        match toml::from_str::<toml::Table>(&text) {
            Ok(t) => d.places.extend(
                in_table(&t)
                    .into_iter()
                    .map(|k| format!("{}: {k}", f.display())),
            ),
            Err(e) => d.warnings.push(format!(
                "{} is not valid TOML; treating it as not setting trim-paths: {e}",
                f.display()
            )),
        }
    }
    d
}

/// The `trim-paths` keys under `[profile]` of one parsed file.
fn in_table(t: &toml::Table) -> Vec<String> {
    let mut keys = Vec::new();
    let Some(toml::Value::Table(profiles)) = t.get("profile") else {
        return keys;
    };
    for (name, p) in profiles {
        let toml::Value::Table(p) = p else { continue };
        if p.contains_key("trim-paths") {
            keys.push(format!("profile.{name}.trim-paths"));
        }
        if let Some(toml::Value::Table(b)) = p.get("build-override")
            && b.contains_key("trim-paths")
        {
            keys.push(format!("profile.{name}.build-override.trim-paths"));
        }
        if let Some(toml::Value::Table(pkgs)) = p.get("package") {
            for (spec, o) in pkgs {
                if let toml::Value::Table(o) = o
                    && o.contains_key("trim-paths")
                {
                    keys.push(format!("profile.{name}.package.{spec}.trim-paths"));
                }
            }
        }
    }
    keys
}

/// Whether breakbulk turns trim-paths on, for a toolchain whose Cargo has
/// the setting (`has`: the toolchain's `trimPaths` capability) or not.
pub fn decide(mode: Mode, has: bool, declared: &Declared) -> Result<bool, Error> {
    match mode {
        Mode::Off => Ok(false),
        Mode::On if !has => Err(Error(
            "cargoTrimPaths = true needs Cargo's trim-paths (stable from Cargo 1.101), which \
             this toolchain does not have (its `trimPaths` capability is false)"
                .into(),
        )),
        Mode::On => Ok(true),
        Mode::Auto => Ok(has && declared.places.is_empty()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, files: &[(&str, &str)]) {
        for (rel, text) in files {
            let p = dir.join(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, text).unwrap();
        }
    }

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "breakbulk-trim-paths-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn finds_every_profile_form() {
        let d = scratch("forms");
        write(
            &d,
            &[
                (
                    "ws/Cargo.toml",
                    "[workspace]\n[profile.release]\nopt-level = 3\n\
                     [profile.dev.package.foo]\ntrim-paths = false\n",
                ),
                (
                    ".cargo/config.toml",
                    "[profile.bench.build-override]\ntrim-paths = \"all\"\n",
                ),
                (
                    "ws/.cargo/config",
                    "[profile.custom]\ntrim-paths = \"none\"\n",
                ),
            ],
        );
        let got = declared(&d.join("ws"));
        assert!(got.warnings.is_empty(), "{got:?}");
        let keys: Vec<&str> = got
            .places
            .iter()
            .map(|p| p.rsplit_once(": ").unwrap().1)
            .collect();
        assert_eq!(
            keys,
            [
                "profile.dev.package.foo.trim-paths",
                "profile.custom.trim-paths",
                "profile.bench.build-override.trim-paths",
            ]
        );
    }

    #[test]
    fn none_declared_and_invalid_toml() {
        let d = scratch("none");
        write(
            &d,
            &[
                ("Cargo.toml", "[workspace]\n[profile.release]\ndebug = 1\n"),
                ("ws/Cargo.toml", "[package\nname = "),
            ],
        );
        let root = declared(&d);
        assert_eq!(root, Declared::default());
        // A broken manifest: a warning, and nothing declared.
        let broken = declared(&d.join("ws"));
        assert!(broken.places.is_empty());
        assert_eq!(broken.warnings.len(), 1, "{broken:?}");
        assert!(broken.warnings[0].contains("not valid TOML"));
        // A trim-paths key outside [profile] does not count.
        write(
            &d,
            &[("Cargo.toml", "[package.metadata]\ntrim-paths = 1\n")],
        );
        assert!(declared(&d).places.is_empty());
    }

    #[test]
    fn decisions() {
        let none = Declared::default();
        let some = Declared {
            places: vec!["Cargo.toml: profile.dev.trim-paths".into()],
            warnings: vec![],
        };
        assert_eq!(decide(Mode::Auto, true, &none), Ok(true));
        assert_eq!(decide(Mode::Auto, true, &some), Ok(false));
        assert_eq!(decide(Mode::Auto, false, &none), Ok(false));
        assert_eq!(decide(Mode::On, true, &some), Ok(true));
        assert!(decide(Mode::On, false, &none).is_err());
        assert_eq!(decide(Mode::Off, true, &none), Ok(false));
        assert_eq!(Mode::parse("auto"), Some(Mode::Auto));
        assert_eq!(Mode::parse("yes"), None);
    }
}
