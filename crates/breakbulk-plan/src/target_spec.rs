//! What the planner takes from its rustc's target spec (`rustc -Z
//! unstable-options --print target-spec-json --target <t>`): the
//! executable suffix of the names bins are stored under, and the
//! debuginfo side files the target's links write
//! ([`breakbulk_format::TargetDebuginfo`]). A custom target (`--target
//! foo.json`) is described by its own spec, as rustc reads it.

use breakbulk_format::{DebugArtifact, DebugArtifactWhen, SplitDebuginfo, TargetDebuginfo};
use serde_json::Value;

use crate::{Error, bail};

/// The parts of a target spec the plan uses.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TargetSpec {
    /// `exe-suffix`: `""`, `.exe`, `.wasm`, `.efi`, … Cargo takes the same
    /// suffix from rustc (`--print file-names`) for the name it uplifts a
    /// bin to.
    pub exe_suffix: String,
    pub debuginfo: TargetDebuginfo,
}

impl TargetSpec {
    /// Read the JSON rustc prints. A key the spec leaves out has rustc's
    /// default: `Target::to_json` writes an option only when it differs
    /// from `TargetOptions::default()` (rustc_target spec/json.rs).
    pub fn from_json(text: &str) -> Result<TargetSpec, Error> {
        let spec: Value = serde_json::from_str(text)
            .map_err(|e| Error(format!("rustc --print target-spec-json: {e}")))?;
        if !spec.is_object() {
            bail!("rustc --print target-spec-json printed no object");
        }
        Ok(TargetSpec {
            exe_suffix: string(&spec, "exe-suffix", "")?.to_owned(),
            debuginfo: debuginfo(&spec)?,
        })
    }
}

fn string<'a>(spec: &'a Value, key: &str, default: &'a str) -> Result<&'a str, Error> {
    match spec.get(key) {
        None => Ok(default),
        Some(Value::String(s)) => Ok(s),
        Some(v) => bail!("rustc --print target-spec-json: `{key}` is {v}, not a string"),
    }
}

fn flag(spec: &Value, key: &str) -> bool {
    spec.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn split(value: &str) -> Result<SplitDebuginfo, Error> {
    SplitDebuginfo::parse(value).ok_or_else(|| {
        Error(format!(
            "rustc --print target-spec-json: unknown split-debuginfo `{value}`"
        ))
    })
}

/// The side files, as rustc_codegen_ssa's back/link.rs writes them:
/// - an MSVC-style linker (`msvc` or `msvc-lld` flavor) always gets
///   `/DEBUG` and writes a `.pdb` (back/linker.rs, `MsvcLinker::debuginfo`);
/// - with packed split debuginfo, `link_natively` runs dsymutil (a `.dSYM`
///   directory) on Darwin-like targets, nothing more on Windows-like ones
///   (the linker's PDB is the packed form), and thorin (a `.dwp`)
///   elsewhere;
/// - with unpacked, DWARF targets (`debuginfo-kind` dwarf,
///   `Session::target_can_use_split_dwarf`) keep a `.dwo` per object.
///
/// Only the split kinds the spec supports count: stable rustc rejects any
/// other (rustc_session session.rs, `SplitDebugInfoUnstablePlatform`).
fn debuginfo(spec: &Value) -> Result<TargetDebuginfo, Error> {
    let split_default = split(string(spec, "split-debuginfo", "off")?)?;
    let supported = match spec.get("supported-split-debuginfo") {
        None => vec![SplitDebuginfo::Off],
        Some(Value::Array(a)) => a
            .iter()
            .map(|v| match v {
                Value::String(s) => split(s),
                v => bail!("rustc --print target-spec-json: split-debuginfo {v} is not a string"),
            })
            .collect::<Result<_, _>>()?,
        Some(v) => bail!(
            "rustc --print target-spec-json: `supported-split-debuginfo` is {v}, not an array"
        ),
    };
    let msvc_linker = matches!(string(spec, "linker-flavor", "gcc")?, "msvc" | "msvc-lld");
    let darwin = flag(spec, "is-like-darwin");
    let windows = flag(spec, "is-like-windows");
    let dwarf = string(spec, "debuginfo-kind", "dwarf")? == "dwarf";
    let artifact = |suffix: &str, when| DebugArtifact {
        suffix: suffix.into(),
        when,
        per_object: false,
        directory: false,
    };
    let mut artifacts = Vec::new();
    if msvc_linker {
        artifacts.push(artifact(".pdb", DebugArtifactWhen::Always));
    }
    if supported.contains(&SplitDebuginfo::Packed) {
        if darwin {
            artifacts.push(DebugArtifact {
                directory: true,
                ..artifact(".dSYM", DebugArtifactWhen::SplitPacked)
            });
        } else if !windows {
            artifacts.push(artifact(".dwp", DebugArtifactWhen::SplitPacked));
        }
    }
    if supported.contains(&SplitDebuginfo::Unpacked) && dwarf {
        artifacts.push(DebugArtifact {
            per_object: true,
            ..artifact(".dwo", DebugArtifactWhen::SplitUnpacked)
        });
    }
    Ok(TargetDebuginfo {
        split_default,
        artifacts,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(json: &str) -> TargetSpec {
        TargetSpec::from_json(json).unwrap()
    }

    fn suffixes(t: &TargetSpec) -> Vec<(&str, DebugArtifactWhen)> {
        t.debuginfo
            .artifacts
            .iter()
            .map(|a| (a.suffix.as_str(), a.when))
            .collect()
    }

    // Excerpts of rustc 1.99's specs: every key rustc printed that these
    // functions read.
    #[test]
    fn built_in_targets() {
        use DebugArtifactWhen::*;
        let linux = read(
            r#"{"linker-flavor":"gnu-cc","os":"linux",
                "supported-split-debuginfo":["packed","unpacked","off"]}"#,
        );
        assert_eq!(linux.exe_suffix, "");
        assert_eq!(linux.debuginfo.split_default, SplitDebuginfo::Off);
        assert_eq!(
            suffixes(&linux),
            [(".dwp", SplitPacked), (".dwo", SplitUnpacked)]
        );
        assert!(linux.debuginfo.artifacts[1].per_object);
        let msvc = read(
            r#"{"binary-format":"coff","debuginfo-kind":"pdb","exe-suffix":".exe",
                "is-like-msvc":true,"is-like-windows":true,"linker-flavor":"msvc",
                "split-debuginfo":"packed","supported-split-debuginfo":["packed"]}"#,
        );
        assert_eq!(msvc.exe_suffix, ".exe");
        assert_eq!(msvc.debuginfo.split_default, SplitDebuginfo::Packed);
        assert_eq!(suffixes(&msvc), [(".pdb", Always)]);
        let uefi = read(
            r#"{"debuginfo-kind":"pdb","exe-suffix":".efi","is-like-windows":true,
                "linker-flavor":"msvc-lld","split-debuginfo":"packed",
                "supported-split-debuginfo":["packed"]}"#,
        );
        assert_eq!(uefi.exe_suffix, ".efi");
        assert_eq!(suffixes(&uefi), [(".pdb", Always)]);
        let darwin = read(
            r#"{"binary-format":"mach-o","debuginfo-kind":"dwarf-dsym","is-like-darwin":true,
                "linker-flavor":"darwin-cc","split-debuginfo":"packed",
                "supported-split-debuginfo":["packed","unpacked","off"]}"#,
        );
        assert_eq!(suffixes(&darwin), [(".dSYM", SplitPacked)]);
        assert!(darwin.debuginfo.artifacts[0].directory);
        assert_eq!(darwin.debuginfo.split_default, SplitDebuginfo::Packed);
        // No split debuginfo: MinGW, wasm, bare metal, the other ELF
        // targets (FreeBSD, riscv64 Linux).
        for json in [
            r#"{"binary-format":"coff","exe-suffix":".exe","is-like-windows":true,
                "linker-flavor":"gnu-cc"}"#,
            r#"{"binary-format":"wasm","exe-suffix":".wasm","is-like-wasm":true,
                "linker-flavor":"wasm-lld"}"#,
            r#"{"linker-flavor":"gnu-lld"}"#,
            r#"{"linker-flavor":"gnu-cc","os":"freebsd"}"#,
        ] {
            assert_eq!(read(json).debuginfo, TargetDebuginfo::default(), "{json}");
        }
    }

    #[test]
    fn rejects_what_it_cannot_read() {
        for json in [
            "[]",
            r#"{"exe-suffix":1}"#,
            r#"{"split-debuginfo":"sometimes"}"#,
            r#"{"supported-split-debuginfo":"packed"}"#,
        ] {
            assert!(TargetSpec::from_json(json).is_err(), "{json}");
        }
    }
}
