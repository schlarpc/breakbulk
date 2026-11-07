//! Records written by the shim into `$BREAKBULK_RECORD`.
//!
//! One JSON file per invocation. File names only need to be unique; the
//! planner orders records by their contents, never by name or time.
//!
//! ```json
//! { "version": 1, "mode": "compile" | "rustdoc" | "run",
//!   "program": ["…/rustc"], "args": ["--crate-name", …],
//!   "cwd": "…", "env": { "KEY": "value" }, …mode-specific fields }
//! ```

use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

pub const RECORD_VERSION: u64 = 1;

pub fn env_map() -> Map<String, Value> {
    let mut vars: Vec<(String, String)> = std::env::vars_os()
        .map(|(k, v)| {
            (
                k.to_string_lossy().into_owned(),
                v.to_string_lossy().into_owned(),
            )
        })
        .collect();
    vars.sort();
    vars.into_iter()
        .map(|(k, v)| (k, Value::String(v)))
        .collect()
}

pub fn cwd() -> String {
    std::env::current_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// A new record with the fields every mode shares.
pub fn base(mode: &str, program: &[String], args: &[String]) -> Map<String, Value> {
    let mut m = Map::new();
    m.insert("version".into(), json!(RECORD_VERSION));
    m.insert("mode".into(), json!(mode));
    m.insert("program".into(), json!(program));
    m.insert("args".into(), json!(args));
    m.insert("cwd".into(), json!(cwd()));
    m.insert("env".into(), Value::Object(env_map()));
    m
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

/// Writes a record atomically (write to a temporary name, then rename).
pub fn write(
    dir: &Path,
    mode: &str,
    label: &str,
    record: Map<String, Value>,
) -> std::io::Result<PathBuf> {
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    std::fs::create_dir_all(dir)?;
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let name = format!(
        "{mode}-{}-{}-{nanos}-{}.json",
        sanitize(label),
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    );
    let path = dir.join(&name);
    let tmp = dir.join(format!(".{name}.tmp"));
    let mut bytes = serde_json::to_vec_pretty(&Value::Object(record))?;
    bytes.push(b'\n');
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, &path)?;
    Ok(path)
}
