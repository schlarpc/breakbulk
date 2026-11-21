//! `breakbulk-predict --spec <file> --out <dir>`: IFD mode's predicted
//! views. `<file>` is a JSON list of [`ViewSpec`]s; each view whose
//! prediction holds is written to `<dir>/views/<index>`, and
//! `<dir>/result.json` maps each key to `{"view": "views/<index>"}` or to
//! `{"fallback": [reason, …]}`, for a unit that keeps its whole view.

use std::collections::BTreeMap;
use std::path::Path;
use std::process::ExitCode;

use breakbulk_predict::view::{Outcome, ViewSpec, materialize, outcome};

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (spec, out) = match &args[..] {
        [a, s, b, o] if a == "--spec" && b == "--out" => (s, o),
        _ => return Err("usage: breakbulk-predict --spec <file> --out <dir>".into()),
    };
    let text = std::fs::read_to_string(spec).map_err(|e| format!("{spec}: {e}"))?;
    let specs: Vec<ViewSpec> = serde_json::from_str(&text).map_err(|e| format!("{spec}: {e}"))?;
    let out = Path::new(out);
    let mut result = BTreeMap::new();
    for (i, s) in specs.iter().enumerate() {
        let r = match outcome(s) {
            Outcome::Files(files) => {
                let rel = format!("views/{i}");
                materialize(Path::new(&s.view), &s.package_dir, &files, &out.join(&rel))
                    .map_err(|e| format!("{}: {e}", s.key))?;
                serde_json::json!({ "view": rel })
            }
            Outcome::Fallback(reasons) => serde_json::json!({ "fallback": reasons }),
        };
        result.insert(s.key.clone(), r);
    }
    std::fs::create_dir_all(out).map_err(|e| e.to_string())?;
    let json = serde_json::to_string_pretty(&result).map_err(|e| e.to_string())?;
    std::fs::write(out.join("result.json"), json).map_err(|e| e.to_string())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("breakbulk-predict: {e}");
            ExitCode::FAILURE
        }
    }
}
