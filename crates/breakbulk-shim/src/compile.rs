//! Compile mode: record the invocation, then fake rustc's outputs.
//!
//! See "Faking a compile" in docs/implementation.md.

use crate::args::RustcArgs;
use crate::stub;
use crate::{Error, record};
use serde_json::json;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

/// One output file rustc would have written, with the `--emit` kind that
/// produces it. The kind is what rustc puts in its artifact notification.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub emit: String,
    pub path: PathBuf,
}

/// Asks the real rustc for the names of the link outputs:
/// the full compile arguments plus `--print=file-names`. rustc stops after
/// printing and does not resolve `--extern` paths, so this works on an empty
/// skeleton.
pub fn file_names(rustc: &str, args: &[String]) -> Result<Vec<String>, Error> {
    let out = Command::new(rustc)
        .args(args)
        .arg("--print=file-names")
        .output()
        .map_err(|e| Error::new(format!("running {rustc} --print=file-names: {e}")))?;
    if !out.status.success() {
        return Err(Error::new(format!(
            "{rustc} --print=file-names failed ({}):\n{}",
            out.status,
            String::from_utf8_lossy(&out.stderr)
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect())
}

/// Every file rustc would write, in the order rustc reports artifacts:
/// dep-info, then metadata, then link outputs (one per crate type), then any
/// other emit kinds.
pub fn outputs(a: &RustcArgs, link_names: &[String]) -> Vec<Output> {
    let dir = a.out_dir();
    let stem = a.stem();
    let mut v = Vec::new();
    let explicit = |kind: &str| -> Option<PathBuf> {
        a.emit_kinds()
            .into_iter()
            .find(|(k, _)| k == kind)
            .and_then(|(_, p)| p.map(PathBuf::from))
    };
    if a.emits("dep-info") {
        v.push(Output {
            emit: "dep-info".into(),
            path: explicit("dep-info").unwrap_or_else(|| dir.join(format!("{stem}.d"))),
        });
    }
    if a.emits("metadata") {
        v.push(Output {
            emit: "metadata".into(),
            path: explicit("metadata").unwrap_or_else(|| dir.join(format!("lib{stem}.rmeta"))),
        });
    }
    if a.emits("link") {
        if let Some(p) = explicit("link") {
            v.push(Output {
                emit: "link".into(),
                path: p,
            });
        } else if let (Some(o), 1) = (&a.output, link_names.len()) {
            v.push(Output {
                emit: "link".into(),
                path: PathBuf::from(o),
            });
        } else {
            for n in link_names {
                v.push(Output {
                    emit: "link".into(),
                    path: dir.join(n),
                });
            }
        }
    }
    for (kind, ext) in [
        ("llvm-ir", "ll"),
        ("asm", "s"),
        ("obj", "o"),
        ("llvm-bc", "bc"),
        ("mir", "mir"),
    ] {
        if a.emits(kind) {
            v.push(Output {
                emit: kind.into(),
                path: explicit(kind).unwrap_or_else(|| dir.join(format!("{stem}.{ext}"))),
            });
        }
    }
    v
}

/// Dep-info in rustc's format: every output depends on the input file.
/// Cargo parses this after every successful compile.
pub fn dep_info(outputs: &[Output], input: &str) -> String {
    let mut s = String::new();
    // rustc lists the dep-info file first, then link outputs, then metadata.
    let mut ordered: Vec<&Output> = outputs.iter().filter(|o| o.emit == "dep-info").collect();
    ordered.extend(outputs.iter().filter(|o| o.emit == "link"));
    ordered.extend(
        outputs
            .iter()
            .filter(|o| o.emit != "dep-info" && o.emit != "link"),
    );
    for o in ordered {
        s.push_str(&format!("{}: {input}\n\n", o.path.display()));
    }
    s.push_str(&format!("{input}:\n"));
    s
}

pub fn artifact_notification(o: &Output) -> String {
    json!({
        "$message_type": "artifact",
        "artifact": o.path.to_string_lossy(),
        "emit": o.emit,
    })
    .to_string()
}

fn is_build_script(a: &RustcArgs) -> bool {
    a.crate_name
        .as_deref()
        .is_some_and(|n| n.starts_with("build_script_"))
        && a.crate_types.iter().all(|t| t == "bin")
}

/// Runs compile mode. `program` is the wrapper chain ending in rustc,
/// `args` the rustc arguments.
pub fn run(
    record_dir: &Path,
    program: &[String],
    args: &[String],
    a: &RustcArgs,
) -> Result<(), Error> {
    let rustc = program.last().expect("program chain is never empty");
    let link_names = if a.emits("link") {
        file_names(rustc, args)?
    } else {
        Vec::new()
    };
    let outs = outputs(a, &link_names);
    let build_script = is_build_script(a);

    let mut rec = record::base("compile", program, args);
    rec.insert("crateName".into(), json!(a.crate_name));
    rec.insert("extraFilename".into(), json!(a.extra_filename));
    rec.insert(
        "outputs".into(),
        json!(
            outs.iter()
                .map(|o| json!({"emit": o.emit, "path": o.path.to_string_lossy()}))
                .collect::<Vec<_>>()
        ),
    );
    rec.insert("buildScript".into(), json!(build_script));
    record::write(record_dir, "compile", &a.stem(), rec)
        .map_err(|e| Error::new(format!("writing record: {e}")))?;

    let input = a.input.clone().unwrap_or_default();
    for o in &outs {
        if let Some(parent) = o.path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent).map_err(|e| Error::io(parent, e))?;
        }
        if o.emit == "dep-info" {
            std::fs::write(&o.path, dep_info(&outs, &input)).map_err(|e| Error::io(&o.path, e))?;
        } else if o.emit == "link" && build_script {
            stub::install(&o.path, record_dir, rustc, a)?;
        } else {
            std::fs::write(&o.path, b"").map_err(|e| Error::io(&o.path, e))?;
        }
    }

    if a.json_artifacts {
        let mut err = std::io::stderr().lock();
        for o in &outs {
            let _ = writeln!(err, "{}", artifact_notification(o));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &[&str]) -> RustcArgs {
        RustcArgs::parse(&s.iter().map(|x| x.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn lib_pipelined_outputs() {
        let a = args(&[
            "--crate-name",
            "foo",
            "src/lib.rs",
            "--crate-type",
            "lib",
            "--emit=dep-info,metadata,link",
            "-C",
            "extra-filename=-ab",
            "--out-dir",
            "/o",
        ]);
        let o = outputs(&a, &["libfoo-ab.rlib".into()]);
        let p: Vec<_> = o
            .iter()
            .map(|o| (o.emit.as_str(), o.path.to_str().unwrap()))
            .collect();
        assert_eq!(
            p,
            [
                ("dep-info", "/o/foo-ab.d"),
                ("metadata", "/o/libfoo-ab.rmeta"),
                ("link", "/o/libfoo-ab.rlib")
            ]
        );
        assert_eq!(
            dep_info(&o, "src/lib.rs"),
            "/o/foo-ab.d: src/lib.rs\n\n/o/libfoo-ab.rlib: src/lib.rs\n\n/o/libfoo-ab.rmeta: src/lib.rs\n\nsrc/lib.rs:\n"
        );
    }

    #[test]
    fn check_mode_has_no_link_outputs() {
        let a = args(&[
            "--crate-name",
            "foo",
            "src/main.rs",
            "--crate-type",
            "bin",
            "--emit=dep-info,metadata",
            "-C",
            "extra-filename=-ab",
            "--out-dir",
            "/o",
        ]);
        let o = outputs(&a, &[]);
        assert_eq!(o.len(), 2);
        assert_eq!(o[1].path, PathBuf::from("/o/libfoo-ab.rmeta"));
    }
}
