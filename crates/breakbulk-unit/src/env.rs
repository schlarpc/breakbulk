//! The environment contract ("Unit execution" in `docs/implementation.md`).
//!
//! A unit's child process (rustc or a build script) gets an environment built
//! from scratch, in layers where later layers win:
//!
//! 1. A fixed base: `HOME=/homeless-shelter`, `LC_ALL=C`, `TZ=UTC`, plus
//!    `TMPDIR` and `NIX_BUILD_CORES` copied from the builder's environment
//!    when Nix set them.
//! 2. The env capture (`env.json`) for the unit's package and platform.
//! 3. to 5. The unit's rendered `env`: Cargo's recorded env, then the toolchain
//!    spec's env, then the package override's env, merged at instantiation.
//!
//! Nothing else from the builder's environment reaches the child: not the
//! derivation's attributes, not the output paths, not `BREAKBULK_UNIT`.
//! Afterwards `NUM_JOBS`, when the unit has it, is replaced with the job
//! count from `NIX_BUILD_CORES`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::Error;

/// The variables of the fixed base that have constant values.
pub const FIXED_BASE: [(&str, &str); 3] = [
    ("HOME", "/homeless-shelter"),
    ("LC_ALL", "C"),
    ("TZ", "UTC"),
];

/// The variables of the fixed base copied from the builder's environment.
pub const PASSED_BASE: [&str; 2] = ["TMPDIR", "NIX_BUILD_CORES"];

/// What `breakbulk-unit` reads from the environment Nix gave it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Outer {
    /// All of the builder's environment. Only [`PASSED_BASE`] and the output
    /// paths are used from it.
    pub vars: BTreeMap<String, String>,
}

impl Outer {
    pub fn from_process() -> Outer {
        Outer {
            vars: std::env::vars_os()
                .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
                .collect(),
        }
    }

    pub fn get(&self, k: &str) -> Option<&str> {
        self.vars.get(k).map(String::as_str)
    }

    /// The build's temporary directory: `$TMPDIR`, or `/tmp`.
    pub fn tmpdir(&self) -> PathBuf {
        PathBuf::from(
            self.get("TMPDIR")
                .filter(|s| !s.is_empty())
                .unwrap_or("/tmp"),
        )
    }

    /// The path of a derivation output, from the variable Nix names after it.
    pub fn output(&self, name: &str) -> Result<PathBuf, Error> {
        match self.get(name) {
            Some(p) if !p.is_empty() => Ok(PathBuf::from(p)),
            _ => Err(Error::new(format!(
                "the derivation output `{name}` is not set in the environment"
            ))),
        }
    }

    /// The job count for `NUM_JOBS`: `NIX_BUILD_CORES`, where `0` (or an
    /// unset or invalid value) means every available CPU, as in Nix.
    pub fn jobs(&self) -> usize {
        match self
            .get("NIX_BUILD_CORES")
            .and_then(|s| s.parse::<usize>().ok())
        {
            Some(n) if n > 0 => n,
            _ => std::thread::available_parallelism().map_or(1, |n| n.get()),
        }
    }

    /// Layer 1.
    pub fn base(&self) -> BTreeMap<String, String> {
        let mut env: BTreeMap<String, String> = FIXED_BASE
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        for k in PASSED_BASE {
            if let Some(v) = self.get(k) {
                env.insert(k.to_owned(), v.to_owned());
            }
        }
        env
    }
}

/// Read an env capture: a JSON object whose values are all strings.
pub fn read_capture(path: &Path) -> Result<BTreeMap<String, String>, Error> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| Error::new(format!("reading env capture {}: {e}", path.display())))?;
    serde_json::from_str(&text).map_err(|e| {
        Error::new(format!(
            "env capture {} is not a JSON object of strings: {e}",
            path.display()
        ))
    })
}

/// Build a child's environment from the layers. `unit_env` is layers 3–5,
/// already merged.
pub fn layered(
    outer: &Outer,
    capture: Option<&BTreeMap<String, String>>,
    unit_env: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let mut env = outer.base();
    if let Some(c) = capture {
        env.extend(c.iter().map(|(k, v)| (k.clone(), v.clone())));
    }
    env.extend(unit_env.iter().map(|(k, v)| (k.clone(), v.clone())));
    if env.contains_key("NUM_JOBS") {
        env.insert("NUM_JOBS".into(), outer.jobs().to_string());
    }
    env
}

#[cfg(test)]
mod tests {
    use super::*;

    fn outer(vars: &[(&str, &str)]) -> Outer {
        Outer {
            vars: vars
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        }
    }

    fn map(vars: &[(&str, &str)]) -> BTreeMap<String, String> {
        vars.iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn nothing_leaks_from_the_builder() {
        let o = outer(&[
            ("TMPDIR", "/build"),
            ("NIX_BUILD_CORES", "4"),
            ("PATH", "/outer/bin"),
            ("out", "/nix/store/x-out"),
            ("BREAKBULK_UNIT", "{}"),
            ("HOME", "/home/me"),
            ("NIX_BUILD_TOP", "/build"),
        ]);
        let env = layered(&o, None, &BTreeMap::new());
        assert_eq!(
            env,
            map(&[
                ("HOME", "/homeless-shelter"),
                ("LC_ALL", "C"),
                ("NIX_BUILD_CORES", "4"),
                ("TMPDIR", "/build"),
                ("TZ", "UTC"),
            ])
        );
    }

    #[test]
    fn later_layers_win() {
        let o = outer(&[("TMPDIR", "/build")]);
        let capture = map(&[("PATH", "/cap/bin"), ("CC", "gcc"), ("TZ", "Europe/Paris")]);
        let unit = map(&[("CC", "clang"), ("CARGO_PKG_NAME", "x")]);
        let env = layered(&o, Some(&capture), &unit);
        assert_eq!(env["PATH"], "/cap/bin");
        assert_eq!(env["CC"], "clang");
        assert_eq!(env["TZ"], "Europe/Paris");
        assert_eq!(env["CARGO_PKG_NAME"], "x");
        assert_eq!(env["HOME"], "/homeless-shelter");
    }

    #[test]
    fn num_jobs_follows_nix_build_cores() {
        let o = outer(&[("NIX_BUILD_CORES", "3")]);
        let env = layered(&o, None, &map(&[("NUM_JOBS", "8")]));
        assert_eq!(env["NUM_JOBS"], "3");
        // Only units that have NUM_JOBS (build-script runs) get it.
        assert!(!layered(&o, None, &BTreeMap::new()).contains_key("NUM_JOBS"));
        // 0 means every CPU.
        let o = outer(&[("NIX_BUILD_CORES", "0")]);
        let n: usize = layered(&o, None, &map(&[("NUM_JOBS", "8")]))["NUM_JOBS"]
            .parse()
            .unwrap();
        assert!(n >= 1);
    }

    #[test]
    fn outputs_and_tmpdir() {
        let o = outer(&[("rlib", "/nix/store/x-rlib"), ("TMPDIR", "")]);
        assert_eq!(
            o.output("rlib").unwrap(),
            PathBuf::from("/nix/store/x-rlib")
        );
        assert!(
            o.output("rmeta")
                .unwrap_err()
                .to_string()
                .contains("`rmeta`")
        );
        assert_eq!(o.tmpdir(), PathBuf::from("/tmp"));
    }
}
