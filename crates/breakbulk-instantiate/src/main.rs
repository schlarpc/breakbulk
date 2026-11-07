//! `breakbulk-instantiate --emit json --plan <plan.json> --sources <file>
//! --toolchains <file> --overrides <file> [--roots <file>] [--out <file>]`
//!
//! Writes `units.json` (IFD mode) to `--out`, or to `$out` when run as a
//! derivation builder.

use std::process::ExitCode;

use breakbulk_format::Plan;
use breakbulk_instantiate::{Inputs, instantiate, to_json};

const USAGE: &str = "usage: breakbulk-instantiate --emit json --plan <plan.json> \
    --sources <sources.json> --toolchains <toolchains.json> --overrides <overrides.json> \
    [--roots <roots.json>] [--out <units.json>]";

fn read(path: &str) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("reading {path}: {e}"))
}

fn parse<T: serde::de::DeserializeOwned>(path: &str) -> Result<T, String> {
    serde_json::from_str(&read(path)?).map_err(|e| format!("{path}: {e}"))
}

fn run() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let mut opts = std::collections::BTreeMap::new();
    while let Some(flag) = args.next() {
        let name = flag
            .strip_prefix("--")
            .filter(|n| {
                matches!(
                    *n,
                    "emit" | "plan" | "sources" | "toolchains" | "overrides" | "roots" | "out"
                )
            })
            .ok_or_else(|| format!("unknown argument `{flag}`\n{USAGE}"))?;
        let value = args
            .next()
            .ok_or_else(|| format!("`{flag}` needs a value\n{USAGE}"))?;
        if opts.insert(name.to_owned(), value).is_some() {
            return Err(format!("`{flag}` given twice\n{USAGE}"));
        }
    }
    let need = |n: &str| {
        opts.get(n)
            .cloned()
            .ok_or_else(|| format!("missing --{n}\n{USAGE}"))
    };
    match need("emit")?.as_str() {
        "json" => {}
        e => return Err(format!("--emit {e}: only `json` (IFD mode) is implemented")),
    }
    let plan_path = need("plan")?;
    let plan = Plan::from_json(&read(&plan_path)?).map_err(|e| format!("{plan_path}: {e}"))?;
    let inputs = Inputs {
        plan,
        sources: parse(&need("sources")?)?,
        toolchains: parse(&need("toolchains")?)?,
        overrides: parse(&need("overrides")?)?,
        roots: opts.get("roots").map(|p| parse(p)).transpose()?,
    };
    let units = instantiate(&inputs).map_err(|e| e.to_string())?;
    let out = match opts.get("out") {
        Some(o) => o.clone(),
        None => std::env::var("out").map_err(|_| "neither --out nor $out is set".to_owned())?,
    };
    std::fs::write(&out, to_json(&units)).map_err(|e| format!("writing {out}: {e}"))
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("breakbulk-instantiate: {e}");
            ExitCode::FAILURE
        }
    }
}
