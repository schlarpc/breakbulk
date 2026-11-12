//! `breakbulk-unit docs`: a plan's documentation, as `cargo doc` writes it.
//!
//! The docs derivation of a doc plan runs the plan's traced `rustdoc`
//! commands one after another into one folder, its output `out`
//! ("Documentation" in `docs/src/explanation/internals/products.md`).
//! Each rustdoc reads the cross-crate files the earlier ones wrote there
//! (the search index, `crates.js`, the trait and type implementor lists) and
//! writes them back with its own crate added, and links to a crate's items
//! only when that crate's directory is already there. Stable rustdoc has no
//! other way to merge crates (`--write-doc-meta-dir`, `--read-doc-meta-dir`
//! and `--merge` are unstable), so the commands share one derivation.
//!
//! Each command is a compile unit's ([`RenderedCompile`], with no outputs and
//! no remapping): its dependency directory is its own, and `-o` names the
//! output. As Cargo does before each rustdoc (cargo `src/compiler/mod.rs`,
//! `rustdoc`), the crate's own directory is removed first. rustdoc's lock
//! file (`.lock`, from `write_shared`) is removed at the end.

use std::path::Path;
use std::process::ExitCode;

use serde::{Deserialize, Serialize};

use crate::compile::{
    Invocation, check_args, fresh_dir, link_deps, load_directives, run_diagnosed,
};
use crate::env::{CFlags, Outer, capture_layer, layered};
use crate::spec::{RenderedArg, RenderedCompile};
use crate::splice::{expand_args, expand_dylib_path, expand_env};
use crate::{Error, io_err};

/// `BREAKBULK_UNIT` of a docs derivation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RenderedDocs {
    /// Always `"docs"`, so that the value cannot be mistaken for a unit.
    pub kind: DocsKind,
    /// The traced `rustdoc` commands, in the order they run. Without `-o`
    /// and `-L dependency=`; `outputs` and `remap` are empty.
    pub commands: Vec<RenderedCompile>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DocsKind {
    Docs,
}

/// rustdoc's lock file in its output directory.
const LOCK_FILE: &str = ".lock";

/// Reject an output directory in the arguments: the derivation adds its own.
fn check_no_output(c: &RenderedCompile) -> Result<(), Error> {
    for a in &c.args {
        if let RenderedArg::Literal(s) = a
            && (s == "-o" || s.starts_with("--output") || s.starts_with("--out-dir"))
        {
            return Err(Error(format!(
                "the rustdoc command of `{}` already names an output directory (`{s}`); the \
                 plan must leave it to breakbulk-unit",
                c.krate.name
            )));
        }
    }
    Ok(())
}

/// One rustdoc command, writing into `out` with `deps` as its dependency
/// directory.
pub fn invocation(
    c: &RenderedCompile,
    outer: &Outer,
    directives: &std::collections::BTreeMap<String, crate::directives::BuildOutput>,
    deps: &Path,
    out: &Path,
) -> Result<Invocation, Error> {
    check_args(c)?;
    check_no_output(c)?;
    if c.program.is_empty() {
        return Err(Error(format!(
            "the rustdoc command of `{}` has an empty program",
            c.krate.name
        )));
    }
    let lookup = |f: &str| directives.get(f);
    let mut argv = c.program.clone();
    argv.extend(expand_args(&c.args, lookup)?);
    argv.extend([
        "-o".to_owned(),
        out.display().to_string(),
        "-L".to_owned(),
        format!("dependency={}", deps.display()),
    ]);
    let mut unit_env = expand_env(&c.env, &c.env_splices, lookup)?;
    expand_dylib_path(&mut unit_env, &c.dylib_path_from, lookup)?;
    let capture = capture_layer(c.env_capture.as_deref(), &c.link_captures)?;
    Ok(Invocation {
        argv,
        env: layered(outer, capture.as_ref(), &unit_env, &CFlags::default()),
        cwd: std::path::PathBuf::from(&c.cwd),
    })
}

/// The whole `docs` mode.
pub fn docs(d: &RenderedDocs, outer: &Outer) -> Result<(), Error> {
    let out = outer.output("out")?;
    fresh_dir(&out)?;
    for (i, c) in d.commands.iter().enumerate() {
        let deps = outer.tmpdir().join(format!("deps-{i}"));
        let directives = load_directives(c)?;
        let inv = invocation(c, outer, &directives, &deps, &out)?;
        link_deps(&c.deps, &deps)?;
        let own = out.join(&c.krate.name);
        if own.symlink_metadata().is_ok() {
            std::fs::remove_dir_all(&own).map_err(|e| io_err("removing", &own, e))?;
        }
        run_diagnosed(&inv, &c.krate.name, "document", &|_| Vec::new())?;
    }
    let lock = out.join(LOCK_FILE);
    if lock.symlink_metadata().is_ok() {
        std::fs::remove_file(&lock).map_err(|e| io_err("removing", &lock, e))?;
    }
    Ok(())
}

/// Read the docs from `BREAKBULK_UNIT` or the file `BREAKBULK_UNITPath`.
pub fn read(outer: &Outer) -> Result<RenderedDocs, Error> {
    let (text, whence) = if let Some(path) = outer.get("BREAKBULK_UNITPath") {
        let text =
            std::fs::read_to_string(path).map_err(|e| io_err("reading", Path::new(path), e))?;
        (text, format!("the file {path}"))
    } else if let Some(text) = outer.get("BREAKBULK_UNIT") {
        (text.to_owned(), "BREAKBULK_UNIT".to_owned())
    } else {
        return Err(Error::new(
            "neither BREAKBULK_UNIT nor BREAKBULK_UNITPath is set",
        ));
    };
    serde_json::from_str(&text).map_err(|e| Error(format!("invalid docs in {whence}: {e}")))
}

/// `breakbulk-unit docs`.
pub fn main() -> ExitCode {
    let outer = Outer::from_process();
    match read(&outer).and_then(|d| docs(&d, &outer)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{CrateInfo, Platform, Splice, SpliceKind};
    use std::collections::BTreeMap;

    fn command(args: Vec<RenderedArg>) -> RenderedCompile {
        RenderedCompile {
            package: "path+file:///w/util#0.1.0".into(),
            krate: CrateInfo {
                name: "util".into(),
                types: vec!["lib".into()],
                edition: "2021".into(),
            },
            platform: Platform::Target,
            program: vec!["/s/rustdoc".into()],
            args,
            env: BTreeMap::from([("CARGO_PKG_NAME".into(), "util".into())]),
            env_splices: vec![Splice::new("/f/a".into(), SpliceKind::RustcEnv)],
            dylib_path_from: vec![],
            cwd: "/src".into(),
            outputs: BTreeMap::new(),
            uplifted: BTreeMap::new(),
            deps: vec![],
            dep_manifests: vec![],
            link_manifest_crates: false,
            manifest_crates: vec![],
            remap: vec![],
            remap_scope: None,
            env_capture: None,
            link_captures: Vec::new(),
            view: None,
            seed: None,
        }
    }

    fn lit(s: &str) -> RenderedArg {
        RenderedArg::Literal(s.into())
    }

    #[test]
    fn invocation_adds_output_and_dependencies() {
        let a = crate::directives::BuildOutput {
            env: vec![("UTIL_NOTE".into(), "x".into())],
            cfgs: vec!["util_generated".into()],
            ..Default::default()
        };
        let dirs = BTreeMap::from([("/f/a".to_owned(), a)]);
        let c = command(vec![
            lit("--crate-name"),
            lit("util"),
            lit("src/lib.rs"),
            lit("--extern"),
            lit("base=/s/libbase.rmeta"),
            RenderedArg::Splice(Splice::new("/f/a".into(), SpliceKind::RustcCfg)),
        ]);
        let inv = invocation(
            &c,
            &Outer::default(),
            &dirs,
            Path::new("/t/deps-0"),
            Path::new("/o"),
        )
        .unwrap();
        assert_eq!(
            inv.argv,
            [
                "/s/rustdoc",
                "--crate-name",
                "util",
                "src/lib.rs",
                "--extern",
                "base=/s/libbase.rmeta",
                "--cfg",
                "util_generated",
                "-o",
                "/o",
                "-L",
                "dependency=/t/deps-0",
            ]
        );
        assert_eq!(inv.env["UTIL_NOTE"], "x");
        assert_eq!(inv.cwd, Path::new("/src"));
    }

    #[test]
    fn rejects_an_output_directory() {
        let dirs = BTreeMap::new();
        for a in [["-o", "/x"], ["--out-dir", "/x"]] {
            let c = command(a.iter().map(|s| lit(s)).collect());
            let e = invocation(
                &c,
                &Outer::default(),
                &dirs,
                Path::new("/d"),
                Path::new("/o"),
            )
            .unwrap_err();
            assert!(e.0.contains("output directory"), "{e}");
        }
    }

    #[test]
    fn parses_with_kind() {
        let d = RenderedDocs {
            kind: DocsKind::Docs,
            commands: vec![command(vec![lit("src/lib.rs")])],
        };
        let json = serde_json::to_string(&d).unwrap();
        assert!(json.starts_with("{\"kind\":\"docs\""), "{json}");
        assert_eq!(serde_json::from_str::<RenderedDocs>(&json).unwrap(), d);
    }
}
