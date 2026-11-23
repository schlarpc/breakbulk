//! The records the shim writes into `$BREAKBULK_RECORD`, one JSON file per
//! invocation, and the planner reads.
//!
//! File names only need to be unique; the planner orders records by their
//! contents, never by name or time.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// The record format version the shim writes and the planner reads.
pub const RECORD_VERSION: u32 = 2;

/// One invocation the shim saw.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Record {
    /// [`RECORD_VERSION`]; [`Record::parse`] checks it.
    #[serde(default)]
    pub version: u32,
    pub mode: Mode,
    /// The program chain: wrappers, then rustc or rustdoc; for a run, the
    /// build script.
    pub program: Vec<String>,
    pub args: Vec<String>,
    pub cwd: String,
    pub env: BTreeMap<String, String>,
    /// Compile records: every file rustc would write.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub outputs: Vec<RecordOutput>,
    /// Run records: the run's tag (the hash in its `OUT_DIR`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    /// Run records: the stub's marker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stub: Option<StubMarker>,
    /// The file the planner read the record from, for messages.
    #[serde(skip)]
    pub file: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Mode {
    /// A rustc compile, faked.
    Compile,
    /// A rustc query (`-vV`, `--print`), passed to the real rustc.
    Query,
    /// A rustdoc command, faked.
    Rustdoc,
    /// A build-script run, by the stub.
    Run,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Compile => "compile",
            Mode::Query => "query",
            Mode::Rustdoc => "rustdoc",
            Mode::Run => "run",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecordOutput {
    /// The `--emit` kind.
    pub emit: String,
    pub path: String,
}

/// The marker beside an installed build-script stub
/// ([`crate::names::STUB_MARKER`]), which the stub copies into its run's
/// record.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StubMarker {
    pub version: u32,
    /// The rustc that compiled the build script.
    pub rustc: String,
    pub compile: StubCompile,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StubCompile {
    /// The file name of the build-script compile's link output.
    pub binary: Option<String>,
}

impl Record {
    /// A record of this process: its environment and working directory.
    pub fn of_process(mode: Mode, program: &[String], args: &[String]) -> Record {
        Record {
            version: RECORD_VERSION,
            mode,
            program: program.to_vec(),
            args: args.to_vec(),
            cwd: std::env::current_dir()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default(),
            env: std::env::vars_os()
                .map(|(k, v)| {
                    (
                        k.to_string_lossy().into_owned(),
                        v.to_string_lossy().into_owned(),
                    )
                })
                .collect(),
            outputs: Vec::new(),
            tag: None,
            stub: None,
            file: String::new(),
        }
    }

    /// Writes the record into `dir` atomically (to a temporary name, then
    /// renamed), named after its mode and `label`.
    pub fn write(&self, dir: &Path, label: &str) -> std::io::Result<PathBuf> {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        std::fs::create_dir_all(dir)?;
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let name = format!(
            "{}-{}-{}-{nanos}-{}.json",
            self.mode.as_str(),
            sanitize(label),
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        let path = dir.join(&name);
        let tmp = dir.join(format!(".{name}.tmp"));
        let mut bytes = serde_json::to_vec_pretty(self)?;
        bytes.push(b'\n');
        std::fs::write(&tmp, bytes)?;
        std::fs::rename(&tmp, &path)?;
        Ok(path)
    }

    /// The record in `text`, which must be of [`RECORD_VERSION`].
    pub fn parse(text: &str) -> Result<Record, String> {
        #[derive(Deserialize)]
        struct Version {
            version: u32,
        }
        let v: Version = serde_json::from_str(text).map_err(|e| e.to_string())?;
        if v.version != RECORD_VERSION {
            return Err(format!(
                "a record of version {}, not {RECORD_VERSION}: the shim and the planner are \
                 from different breakbulk versions",
                v.version
            ));
        }
        serde_json::from_str(text).map_err(|e| e.to_string())
    }
}

fn sanitize(label: &str) -> String {
    label
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_version() {
        let mut r = Record::of_process(Mode::Run, &["/b/build-script".into()], &[]);
        r.tag = Some("0123".into());
        r.stub = Some(StubMarker {
            version: RECORD_VERSION,
            rustc: "/r/rustc".into(),
            compile: StubCompile {
                binary: Some("build_script_build-1".into()),
            },
        });
        let text = serde_json::to_string(&r).unwrap();
        assert!(text.contains("\"mode\":\"run\""), "{text}");
        assert_eq!(Record::parse(&text).unwrap(), r);
        let old = text.replace("\"version\":2", "\"version\":1");
        assert!(Record::parse(&old).unwrap_err().contains("version 1"));
    }
}
